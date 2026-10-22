import AppKit
import AudioEngine
import AudioTagging
import Downloader
import JobSystem
import MediaModel
import Observation

/// A YouTube link: looked up, shown with a list of formats, then
/// downloaded by the Downloader XPC service and saved to ~/Downloads in
/// the chosen format.
@MainActor
@Observable
final class LinkDownload {
    enum Stage: Equatable {
        case idle
        case lookingUp
        case choosing
        case downloading(LinkDownloadPhase)
        case saving(Double)
        case done(URL)
        case failed(String)
    }

    var text = ""
    private(set) var stage: Stage = .idle
    private(set) var info: LinkInfo?
    private(set) var thumbnail: NSImage?
    enum Kind: String, CaseIterable, Identifiable {
        case audio, video
        var id: Self { self }
    }

    // Changing any choice after a download (or a failure) brings the
    // Download button back, so another format or quality can be saved.
    var kind: Kind = .audio { didSet { readyForAnother() } }
    /// The format to save. AAC is YouTube's own audio, kept exactly.
    var format: AudioFormat = .aac { didSet { readyForAnother() } }
    /// The chosen video quality (a format ID); the best is chosen on lookup.
    var videoFormat: String? { didSet { readyForAnother() } }
    /// Only H.264 (up to 1080p), which every device plays.
    var playsEverywhere = false {
        didSet {
            if !videoChoices.contains(where: { $0.id == videoFormat }) { videoFormat = defaultVideo?.id }
            readyForAnother()
        }
    }
    var mp3BitRate = AudioRequest.maximumBitRate { didSet { readyForAnother() } }

    /// Back from "Saved" (or an error) to choosing, on the same video.
    func readyForAnother() {
        switch stage {
        case .done, .failed: if info != nil { stage = .choosing }
        default: break
        }
    }
    var isShowingSheet = false

    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var link: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private lazy var progress = ProgressReceiver { [weak self] phase in
        Task { @MainActor in
            guard let self, case .downloading = self.stage else { return }
            self.stage = .downloading(phase)
        }
    }

    var parsedLink: URL? { LinkDownloader.link(in: text) }
    /// The format page replaces the window's content while it's up.
    var isPageVisible: Bool { stage != .idle }
    var isBusy: Bool {
        switch stage {
        case .lookingUp, .downloading, .saving: true
        default: false
        }
    }

    // MARK: - Steps

    /// Step 1: look the video up, then show the formats.
    func lookUp() {
        guard let parsedLink, !isBusy else { return }
        link = parsedLink
        info = nil
        thumbnail = nil
        stage = .lookingUp
        isShowingSheet = false
        proxy()?.info(parsedLink.absoluteString) { [weak self] data, message in
            Task { @MainActor in
                guard let self, self.stage == .lookingUp else { return }
                if let data, let info = try? JSONDecoder().decode(LinkInfo.self, from: data) {
                    self.info = info
                    self.thumbnail = info.thumbnail.flatMap(NSImage.init(data:))
                    self.videoFormat = self.defaultVideo?.id
                    self.stage = .choosing
                } else {
                    self.stage = message.map { .failed($0) } ?? .idle
                }
            }
        }
    }

    /// The qualities to show: AV1 and H.264 (or only H.264), best first,
    /// one per resolution, frame rate and HDR.
    var videoChoices: [VideoOption] {
        // Plays everywhere: only H.264, including sizes converted from AV1.
        let options = (info?.videoOptions ?? []).filter { playsEverywhere ? $0.isH264 : !$0.isConverted }
        var seen: Set<String> = []
        return options.filter { seen.insert("\($0.height)-\($0.fps)-\($0.isHDR)").inserted }
    }

    /// The best stream as YouTube has it; converted sizes are only used
    /// when picked.
    var defaultVideo: VideoOption? { videoChoices.first { !$0.isConverted } }

    var selectedVideo: VideoOption? { videoChoices.first { $0.id == videoFormat } }

    /// Step 2: download, then save in the chosen format.
    func download() {
        guard let link, stage == .choosing || isFailed else { return }
        if kind == .video {
            guard let option = selectedVideo else { return }
            stage = .downloading(.downloading(0))
            proxy()?.downloadVideo(link.absoluteString, format: option.formatID, convert: option.isConverted) { [weak self] path, message in
                Task { @MainActor in
                    guard let self, case .downloading = self.stage else { return }
                    if let path {
                        self.moveVideo(URL(fileURLWithPath: path))
                    } else {
                        self.stage = message.map { .failed($0) } ?? .choosing
                    }
                }
            }
            return
        }
        stage = .downloading(.downloading(0))
        proxy()?.download(link.absoluteString) { [weak self] path, message in
            Task { @MainActor in
                guard let self, case .downloading = self.stage else { return }
                if let path {
                    self.save(URL(fileURLWithPath: path))
                } else {
                    self.stage = message.map { .failed($0) } ?? .choosing
                }
            }
        }
    }

    private var isFailed: Bool { if case .failed = stage { true } else { false } }

    /// AAC is moved as it is; anything else goes through the audio engine
    /// with the downloaded tags and cover. The intermediate file is removed.
    private func save(_ downloaded: URL) {
        let format = format
        let bitRate = format == .mp3 ? mp3BitRate : nil
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = SafeOutput.defaultDestination(
            for: folder.appendingPathComponent(downloaded.deletingPathExtension().lastPathComponent)
                .appendingPathExtension(format.fileExtension),
            pathExtension: format.fileExtension
        )
        stage = .saving(0)
        saveTask = Task {
            defer { try? FileManager.default.removeItem(at: DownloaderService.stagingFolder) }
            do {
                if format == .aac {
                    try FileManager.default.moveItem(at: downloaded, to: destination)
                } else {
                    let info = try await AudioEngine.inspectAsync(url: downloaded)
                    let tags = await AudioTagging.tags(of: downloaded)
                    let plan = try AudioPlanner.plan(info, AudioRequest(
                        target: format, bitRate: bitRate, segments: [SampleRange(0, info.frames)], tags: tags
                    ))
                    try await AudioEngine.export(downloaded, plan: plan, to: destination) { fraction in
                        Task { @MainActor in
                            guard case .saving = self.stage else { return }
                            self.stage = .saving(fraction)
                        }
                    }
                }
                stage = .done(destination)
            } catch is CancellationError {
                stage = .choosing
            } catch {
                stage = .failed(String(describing: error))
            }
        }
    }

    /// The joined MP4 goes from the staging folder into Downloads.
    private func moveVideo(_ file: URL) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = SafeOutput.defaultDestination(for: folder.appendingPathComponent(file.lastPathComponent), pathExtension: "mp4")
        defer { try? FileManager.default.removeItem(at: DownloaderService.stagingFolder) }
        do {
            try FileManager.default.moveItem(at: file, to: destination)
            stage = .done(destination)
        } catch {
            stage = .failed(String(describing: error))
        }
    }

    func cancel() {
        (connection?.remoteObjectProxy as? DownloaderServiceProtocol)?.cancel()
        saveTask?.cancel()
        stage = info == nil ? .idle : .choosing
    }

    /// Leaves the page (cancelling anything running).
    func close() {
        if isBusy { cancel() }
        stage = .idle
        info = nil
        thumbnail = nil
        videoFormat = nil
        text = ""
    }

    // MARK: - Service

    private func proxy() -> DownloaderServiceProtocol? {
        service().remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in self?.stage = .failed("The downloader stopped unexpectedly: \(error.localizedDescription)") }
        } as? DownloaderServiceProtocol
    }

    private func service() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(serviceName: DownloaderService.name)
        connection.remoteObjectInterface = NSXPCInterface(with: DownloaderServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: DownloaderProgressProtocol.self)
        connection.exportedObject = progress
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.resume()
        self.connection = connection
        return connection
    }
}

/// The formats offered for a link, in order, and what each one means.
enum LinkFormatOption {
    static let formats: [AudioFormat] = [.aac, .mp3, .flac, .alac, .wav, .aiff]

    static func title(_ format: AudioFormat) -> String {
        format == .aac ? "AAC (M4A)" : format.displayName
    }

    static func detail(_ format: AudioFormat, sourceKbps: Int?) -> String {
        let source = sourceKbps.map { "\($0) kbit/s" } ?? "YouTube's"
        return switch format {
        case .aac: "The audio exactly as YouTube streams it (\(source)), with no re-encoding. Plays on Apple devices, phones and most players."
        case .mp3: "Plays everywhere. Converted from YouTube's AAC, so it loses a little, like every YouTube-to-MP3 site; a higher bit rate doesn't restore detail."
        case .flac: "Lossless: stores the decoded audio with no further loss. Larger, not better than AAC."
        case .alac: "Apple's lossless format (M4A). No further loss; larger."
        case .wav: "Uncompressed, for editing software. No further loss; much larger; no cover art."
        case .aiff: "Uncompressed, Apple's older format. No further loss; much larger; no cover art."
        }
    }
}

/// Receives progress from the service (on an XPC thread).
private final class ProgressReceiver: NSObject, DownloaderProgressProtocol, @unchecked Sendable {
    private let update: @Sendable (LinkDownloadPhase) -> Void

    init(_ update: @escaping @Sendable (LinkDownloadPhase) -> Void) { self.update = update }

    func phase(_ kind: Int, fraction: Double) {
        switch kind {
        case 0: update(.settingUp)
        case 1: update(.updating)
        case 3: update(.finishing)
        case 4: update(.converting(fraction))
        default: update(.downloading(fraction))
        }
    }
}
