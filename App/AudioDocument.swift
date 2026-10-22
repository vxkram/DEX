import AppKit
import AudioEngine
import AudioTagging
import ImageIO
import AVFoundation
import JobSystem
import MediaModel
import Observation
import UniformTypeIdentifiers

/// The audio file open in the window and the edit being set up. Media work
/// happens in DexCore; this holds UI state and playback.
@MainActor
@Observable
final class AudioDocument {
    typealias ExportState = ImageDocument.ExportState

    let url: URL
    private(set) var info: AudioInfo?
    private(set) var waveform: Waveform?
    private(set) var analysisProgress: Double = 0
    private(set) var loadError: String?

    var tool: AudioTool? = .trim
    /// Only the trim is edited in the app; the engine can also cut and split.
    var edit = AudioEdit()
    /// Title, artist, album and cover as they'll be saved; starts as the
    /// file's own.
    var tags = AudioTags() {
        didSet { if tags.artwork != oldValue.artwork { artworkImage = tags.artwork.flatMap { NSImage(data: $0.data) } } }
    }
    private(set) var sourceTags = AudioTags()
    private(set) var artworkImage: NSImage?
    var target: AudioFormat = .wav
    /// nil = best: keep the source's data, or the highest bit rate.
    var bitRate: Int?

    // MARK: Timeline view
    private(set) var playhead: Int64 = 0
    /// The span of the file shown in the waveform.
    var visible = SampleRange(0, 1)
    private(set) var isPlaying = false

    var exportState: ExportState = .idle
    private(set) var estimate: (key: AudioRequest, bytes: Int64?)?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    // MARK: - Loading

    func load() async {
        do {
            let info = try await AudioEngine.inspectAsync(url: url)
            self.info = info
            target = info.format ?? .flac
            visible = SampleRange(0, info.frames)
            sourceTags = await AudioTagging.tags(of: url)
            tags = sourceTags
            player = try? AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            analysisTask = Task { await analyse() }
        } catch {
            loadError = String(describing: error)
        }
    }

    private func analyse() async {
        let url = url
        do {
            let waveform = try await AudioEngine.waveform(url: url) { [weak self] fraction in
                Task { @MainActor in self?.analysisProgress = fraction }
            }
            self.waveform = waveform
            // The peak decides whether an integer format would clip.
            info?.peak = waveform.peak
        } catch {
            if !(error is CancellationError) { loadError = String(describing: error) }
        }
    }

    /// Stops playback and background work when another file replaces this one.
    func close() {
        stop()
        analysisTask?.cancel()
        exportTask?.cancel()
    }

    var frames: Int64 { info?.frames ?? 0 }
    var sampleRate: Double { info?.sampleRate ?? 44_100 }

    // MARK: - Edit

    var kept: SampleRange { edit.kept(length: frames) }
    var segments: [SampleRange] { edit.segments(length: frames) }
    var outputLength: Int64 { edit.outputLength(length: frames) }

    func setTrimStart(_ frame: Int64) {
        let kept = kept
        edit.trim = SampleRange(min(max(frame, 0), kept.end - 1), kept.end)
        normaliseTrim()
    }

    func setTrimEnd(_ frame: Int64) {
        let kept = kept
        edit.trim = SampleRange(kept.start, max(min(frame, frames), kept.start + 1))
        normaliseTrim()
    }

    private func normaliseTrim() {
        if edit.trim == SampleRange(0, frames) { edit.trim = nil }
    }

    func resetTrim() { edit.trim = nil }

    // MARK: - Artwork

    func presentArtworkPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose cover art. It's saved into MP3, M4A and FLAC exports."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setArtwork(from: url)
    }

    /// JPEG and PNG are used as they are; other formats (HEIC, WebP…) and
    /// anything larger than 3000 px become a JPEG, since players expect those.
    func setArtwork(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        if ["public.jpeg", "public.png"].contains(type) && max(width, height) <= 3000 {
            tags.artwork = Artwork(data: data)
            return
        }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 3000,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        if CGImageDestinationFinalize(destination) { tags.artwork = Artwork(data: output as Data) }
    }

    func removeArtwork() { tags.artwork = nil }

    // MARK: - Playback

    func togglePlayback() {
        isPlaying ? stop() : play()
    }

    func play() {
        guard let player else { return }
        if !kept.contains(playhead) || playhead >= kept.end - Int64(sampleRate / 20) { playhead = kept.start }
        player.currentTime = Double(playhead) / sampleRate
        player.play()
        isPlaying = true
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                self?.tick()
            }
        }
    }

    func stop() {
        player?.pause()
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
    }

    /// Follows the player; playback stops at the end of the trim.
    private func tick() {
        guard let player, isPlaying else { return }
        var frame = Int64(player.currentTime * sampleRate)
        if frame >= kept.end || !player.isPlaying {
            stop()
            frame = min(frame, kept.end)
        }
        playhead = frame
        keepPlayheadVisible()
    }

    func seek(to frame: Int64) {
        playhead = min(max(frame, 0), frames)
        if isPlaying { player?.currentTime = Double(playhead) / sampleRate }
    }

    // MARK: - Zoom

    /// Shortest span the waveform zooms to: about 20 ms.
    private var minimumVisible: Int64 { max(Int64(sampleRate / 50), 64) }

    func zoom(by factor: Double, around anchor: Int64? = nil) {
        guard frames > 0 else { return }
        let anchor = anchor ?? playhead
        let length = min(max(Int64(Double(visible.length) / factor), minimumVisible), frames)
        let ratio = visible.length > 0 ? Double(anchor - visible.start) / Double(visible.length) : 0.5
        var start = anchor - Int64(Double(length) * min(max(ratio, 0), 1))
        start = min(max(start, 0), frames - length)
        visible = SampleRange(start, start + length)
    }

    /// Zooms keeping the frame at `fraction` (0...1 across the waveform)
    /// under the pointer. Uses the current span, not the last drawn one, so
    /// fast scroll events can't drift.
    func zoom(by factor: Double, atFraction fraction: Double) {
        let anchor = visible.start + Int64(Double(visible.length) * min(max(fraction, 0), 1))
        zoom(by: factor, around: anchor)
    }

    func zoomToFit() { visible = SampleRange(0, frames) }

    /// Zooms to what's kept.
    func zoomToTrim() {
        let range = kept
        let pad = range.length / 20
        visible = SampleRange(max(range.start - pad, 0), min(range.end + pad, frames))
    }

    func scrollVisible(to start: Int64) {
        let length = visible.length
        let clamped = min(max(start, 0), max(frames - length, 0))
        visible = SampleRange(clamped, clamped + length)
    }

    var isZoomed: Bool { visible.length < frames }

    private func keepPlayheadVisible() {
        guard isZoomed, !visible.contains(playhead) else { return }
        scrollVisible(to: playhead - visible.length / 10)
    }

    // MARK: - Planning

    var request: AudioRequest {
        AudioRequest(target: target, bitRate: target.isLossless ? nil : bitRate, segments: segments, tags: tags)
    }

    var planResult: Result<AudioPlan, any Error>? {
        guard let info else { return nil }
        return Result { try AudioPlanner.plan(info, request) }
    }

    var plan: AudioPlan? { try? planResult?.get() }

    var isExporting: Bool {
        if case .running = exportState { true } else { false }
    }

    var canExport: Bool { plan != nil && !isExporting }

    /// Measures the output size (predicted, or by encoding a sample).
    func refreshEstimate() async {
        guard let plan else { estimate = nil; return }
        let key = request
        if let predicted = plan.predictedBytes {
            estimate = (key, predicted)
            return
        }
        estimate = (key, nil)
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled, request == key,
              let bytes = try? await AudioEngine.estimatedSize(url, plan: plan), request == key
        else { return }
        estimate = (key, bytes)
    }

    var currentEstimate: Int64? {
        estimate?.key == request ? estimate?.bytes : nil
    }

    // MARK: - Export

    func export() {
        if tool != .convert {
            tool = .convert
        } else {
            presentSavePanel()
        }
    }

    private var baseName: String { url.deletingPathExtension().lastPathComponent }

    private func presentSavePanel() {
        guard let plan, !isExporting else { return }
        let panel = NSSavePanel()
        let format = plan.request.target
        let edited = edit.isIdentity ? "" : " (trimmed)"
        panel.nameFieldStringValue = SafeOutput.defaultDestination(
            for: url.deletingLastPathComponent().appendingPathComponent(baseName + edited).appendingPathExtension(format.fileExtension),
            pathExtension: format.fileExtension
        ).lastPathComponent
        panel.directoryURL = url.deletingLastPathComponent()
        panel.allowedContentTypes = UTType(format.typeIdentifier).map { [$0] } ?? []
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let losses = plan.notes.filter(\.isLoss).map(\.description)
        panel.message = losses.isEmpty
            ? "\(plan.verdict.label): no quality is lost."
            : "This export loses information: " + losses.joined(separator: "; ") + "."
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            MainActor.assumeIsolated { self?.startExport(plan, to: destination) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    private func startExport(_ plan: AudioPlan, to destination: URL) {
        let source = url
        exportState = .running(0)
        exportTask = Task {
            do {
                // The save panel already asked before replacing a file; the
                // original itself is always protected by SafeOutput.
                try await AudioEngine.export(source, plan: plan, to: destination, overwrite: true) { fraction in
                    Task { @MainActor in
                        guard case .running = self.exportState else { return }
                        self.exportState = .running(fraction)
                    }
                }
                exportState = .saved(destination)
            } catch is CancellationError {
                exportState = .idle
            } catch {
                exportState = .failed(String(describing: error))
            }
        }
    }

    func cancelExport() { exportTask?.cancel() }

    func dismissExportStatus() {
        if !isExporting { exportState = .idle }
    }
}

enum AudioTool: String, CaseIterable, Identifiable {
    case trim, convert, info

    var id: Self { self }

    var title: String {
        switch self {
        case .trim: "Trim"
        case .convert: "Convert"
        case .info: "Info"
        }
    }

    var symbol: String {
        switch self {
        case .trim: "arrow.left.and.right.square"
        case .convert: "arrow.triangle.2.circlepath"
        case .info: "info.circle"
        }
    }
}

/// "1:23.456": minutes, seconds and milliseconds (hours when needed).
enum TimeText {
    static func string(_ frame: Int64, rate: Double, precise: Bool = true) -> String {
        let seconds = Double(frame) / max(rate, 1)
        let total = Int(seconds)
        let millis = Int(((seconds - Double(total)) * 1000).rounded(.down))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        let base = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        return precise ? base + String(format: ".%03d", millis) : base
    }

    /// Accepts "83.5", "1:23.5" or "1:02:03.25".
    static func frame(from text: String, rate: Double) -> Int64? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            seconds = seconds * 60 + value
        }
        return Int64((seconds * rate).rounded())
    }
}
