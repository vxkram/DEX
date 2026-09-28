import AppKit
import ImageEngine
import JobSystem
import MediaModel
import Observation
import UniformTypeIdentifiers

/// The file currently open in the window and the conversion being set up.
/// All media work happens in DexCore; this only holds UI state.
@MainActor
@Observable
final class ImageDocument {
    enum ExportState: Equatable {
        case idle
        case running(Double)
        case saved(URL)
        case failed(String)
    }

    private(set) var sourceURL: URL?
    private(set) var info: MediaInfo?
    private(set) var preview: PreviewImage?
    private(set) var loadError: String?
    private(set) var isLoading = false

    var target: ImageFormat = .jpeg
    var quality: QualityPreference = .maximum
    var metadata: MetadataPolicy = .removeLocation
    var exportState: ExportState = .idle
    var isConfirmingLossyExport = false

    /// Formats this Mac can write, in display order.
    let writableFormats: [ImageFormat]

    @ObservationIgnored private var accessedURL: URL?
    @ObservationIgnored private var exportTask: Task<Void, Never>?

    init() {
        let writable = ImageEngine.writableFormats()
        writableFormats = [.jpeg, .png, .heic, .avif, .webp, .tiff, .gif].filter(writable.contains)
    }

    // MARK: - Derived state

    var request: ConvertRequest {
        ConvertRequest(target: target, quality: quality, metadata: metadata)
    }

    /// Recomputed live as settings change. Planning is pure and cheap.
    var planResult: Result<ConversionPlan, any Error>? {
        guard let info else { return nil }
        return Result { try Planner.plan(info, request, writable: Set(writableFormats)) }
    }

    var plan: ConversionPlan? { try? planResult?.get() }

    var isExporting: Bool {
        if case .running = exportState { true } else { false }
    }

    var canExport: Bool { plan != nil && !isExporting }

    // MARK: - Opening

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await open(url) }
    }

    func open(_ url: URL) async {
        exportTask?.cancel()
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = url.startAccessingSecurityScopedResource() ? url : nil

        sourceURL = url
        info = nil
        preview = nil
        loadError = nil
        exportState = .idle
        isLoading = true

        do {
            let info = try await ImageEngine.inspectAsync(url: url)
            guard sourceURL == url else { return }
            self.info = info
            target = Self.suggestedTarget(for: info, writable: writableFormats)
            let preview = try await ImageEngine.preview(url: url)
            guard sourceURL == url else { return }
            self.preview = preview
        } catch {
            if sourceURL == url { loadError = String(describing: error) }
        }
        if sourceURL == url { isLoading = false }
    }

    /// HEIC and other modern formats default to JPEG, the most compatible
    /// choice; everything else stays in its own format.
    static func suggestedTarget(for info: MediaInfo, writable: [ImageFormat]) -> ImageFormat {
        let preferred: ImageFormat = switch info.format {
        case .heic, .heif, .avif, .webp, nil: .jpeg
        case let format?: format
        }
        return writable.contains(preferred) ? preferred : (writable.first ?? .png)
    }

    // MARK: - Exporting

    func requestExport() {
        guard let plan, !isExporting else { return }
        if plan.verdict == .lossy {
            isConfirmingLossyExport = true
        } else {
            presentSavePanel()
        }
    }

    func useLosslessAlternative() {
        guard let alternative = plan?.losslessAlternative else { return }
        target = alternative
        presentSavePanel()
    }

    func presentSavePanel() {
        guard let sourceURL, let plan else { return }
        let panel = NSSavePanel()
        let format = plan.request.target
        panel.nameFieldStringValue = SafeOutput.defaultDestination(
            for: sourceURL, pathExtension: format.preferredFileExtension
        ).lastPathComponent
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        panel.allowedContentTypes = UTType(format.typeIdentifier).map { [$0] } ?? []
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

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

    func cancelExport() {
        exportTask?.cancel()
    }

    private func startExport(_ plan: ConversionPlan, to destination: URL) {
        guard let source = sourceURL else { return }
        exportState = .running(0)
        exportTask = Task {
            do {
                // The save panel already asked before replacing an existing
                // file; the original itself is always protected by SafeOutput.
                try await ImageEngine.convert(source, plan: plan, to: destination, overwrite: true) { fraction in
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

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
