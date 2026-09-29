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
    /// Rotate/flip, crop and resize, all in display space.
    var geometry = Geometry()
    var cropAspect: CropAspect = .free
    /// Lossless compression (Compress → Lossless).
    var optimize = false

    // MARK: Compose state
    var composeMode: ComposeMode = .layers
    var layers: [OverlayLayer] = []
    var arrangedImages: [ComposedImage] = []
    var spacing = 0
    var sizing: Arrangement.Sizing = .matchSmallest
    var alignment: Arrangement.Alignment = .center
    var background: Arrangement.Background = .white
    var gridColumns = 2
    var selectedLayerID: UUID?
    /// Small previews of added images, for the canvas and the list.
    private(set) var extraPreviews: [URL: PreviewImage] = [:]
    /// Why an added image couldn't be used, if one couldn't.
    var composeWarning: String?
    @ObservationIgnored private var accessedExtras: Set<URL> = []
    var exportState: ExportState = .idle
    /// The real output size for the current settings, when known.
    private(set) var estimate: SizeEstimate?

    /// The tool panel that is open (nil = none).
    var tool: Tool? = .convert
    /// Set while a crop corner or edge is being dragged; drives the loupe.
    var cropDrag: CropDrag?
    /// Full-resolution pixels in display space for the loupe.
    private(set) var loupeImage: LoupeImage?
    @ObservationIgnored private var loupeTask: Task<Void, Never>?

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
        ConvertRequest(target: target, quality: quality, metadata: metadata, geometry: geometry, optimize: optimize,
                       composition: composition)
    }

    /// Size as shown after the file's orientation and the user's rotate/flip.
    var displaySize: PixelSize? {
        guard let info else { return nil }
        return Orientation(exif: info.orientation).followed(by: geometry.orientation).apply(to: info.storedSize)
    }

    /// The crop that will actually be written (JPEG crops may snap).
    var effectiveCrop: PixelRect? { plan?.displayCrop ?? geometry.crop }

    /// Size after cropping, before resizing.
    var croppedSize: PixelSize? { effectiveCrop?.size ?? displaySize }

    var hasEdits: Bool { !geometry.isIdentity }

    // MARK: Compose

    var composition: Composition? {
        switch composeMode {
        case .layers:
            return layers.isEmpty ? nil : .layers(layers)
        case .horizontal, .vertical, .grid:
            return arrangedImages.isEmpty ? nil : .arrangement(arrangement)
        }
    }

    var arrangement: Arrangement {
        let layout: Arrangement.Layout = switch composeMode {
        case .vertical: .vertical
        case .grid: .grid(columns: gridColumns)
        default: .horizontal
        }
        return Arrangement(layout: layout, images: arrangedImages, spacing: spacing, sizing: sizing,
                           alignment: alignment, background: background)
    }

    /// Images the user has added, in the current mode.
    var composedImages: [ComposedImage] {
        composeMode == .layers ? layers.map(\.image) : arrangedImages
    }

    func presentAddImagesPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose images to combine with \(sourceURL?.lastPathComponent ?? "this image"). Any format works."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await addImages(urls) }
    }

    /// Adds images of any readable format to the composition.
    func addImages(_ urls: [URL]) async {
        composeWarning = nil
        for url in urls where url != sourceURL {
            if url.startAccessingSecurityScopedResource() { accessedExtras.insert(url) }
            let info: MediaInfo
            do {
                info = try await ImageEngine.inspectAsync(url: url)
            } catch {
                composeWarning = String(describing: error)
                continue
            }
            let image = ComposedImage(url: url, info: info)
            guard !composedImages.contains(image) else { continue }
            if composeMode == .layers {
                let layer = OverlayLayer.placed(image, on: croppedSize ?? info.displaySize)
                layers.append(layer)
                selectedLayerID = layer.id
            } else {
                arrangedImages.append(image)
            }
            if let preview = try? await ImageEngine.preview(url: url, maxPixelSize: 1024) {
                extraPreviews[url] = preview
            }
        }
    }

    func removeImage(_ image: ComposedImage) {
        layers.removeAll { $0.image == image }
        arrangedImages.removeAll { $0 == image }
        if accessedExtras.remove(image.url) != nil { image.url.stopAccessingSecurityScopedResource() }
        extraPreviews[image.url] = nil
    }

    /// Moves an image earlier (up) or later in the order; for layers,
    /// later means drawn on top.
    func move(_ image: ComposedImage, by offset: Int) {
        if let index = layers.firstIndex(where: { $0.image == image }) {
            let target = min(max(index + offset, 0), layers.count - 1)
            layers.swapAt(index, target)
        } else if let index = arrangedImages.firstIndex(of: image) {
            let target = min(max(index + offset, 0), arrangedImages.count - 1)
            arrangedImages.swapAt(index, target)
        }
    }

    /// Switching between layers and arrangements carries the images over.
    func setComposeMode(_ mode: ComposeMode) {
        let images = composedImages
        let wasLayers = composeMode == .layers
        composeMode = mode
        if wasLayers && mode != .layers {
            arrangedImages = images
        } else if !wasLayers && mode == .layers {
            let canvas = croppedSize ?? PixelSize(width: 1, height: 1)
            layers = images.map { OverlayLayer.placed($0, on: canvas) }
            selectedLayerID = layers.last?.id
        }
    }

    func updateLayer(_ id: UUID, _ change: (inout OverlayLayer) -> Void) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        change(&layers[index])
    }

    private func releaseExtras() {
        for url in accessedExtras { url.stopAccessingSecurityScopedResource() }
        accessedExtras = []
        extraPreviews = [:]
        layers = []
        arrangedImages = []
        selectedLayerID = nil
    }

    func rotateClockwise() { geometry.rotateClockwise(); geometry.resize = nil }
    func rotateCounterclockwise() { geometry.rotateCounterclockwise(); geometry.resize = nil }
    func flipHorizontally() { geometry.flipHorizontally(); geometry.resize = nil }
    func flipVertically() { geometry.flipVertically(); geometry.resize = nil }
    func resetGeometry() { geometry = Geometry() }

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
        releaseExtras()
        geometry = Geometry()
        cropAspect = .free
        optimize = false
        quality = .maximum
        estimate = nil
        cropDrag = nil
        loupeTask?.cancel()
        loupeImage = nil
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

    /// Runs the real conversion in the background to measure the output
    /// size. Called from a view task keyed on the request, so a newer
    /// request cancels an older estimate.
    func refreshEstimate() async {
        guard let sourceURL, let plan else {
            estimate = nil
            return
        }
        let request = plan.request
        estimate = SizeEstimate(request: request, bytes: nil)
        do {
            try await Task.sleep(for: .milliseconds(350))
            let bytes = try await ImageEngine.estimatedSize(sourceURL, plan: plan)
            if self.request == request { estimate = SizeEstimate(request: request, bytes: bytes) }
        } catch {
            if self.request == request, !(error is CancellationError) {
                estimate = SizeEstimate(request: request, bytes: nil, failure: String(describing: error))
            }
        }
    }

    /// Re-measures when the file finishes loading as well as when a
    /// setting changes.
    var estimateKey: EstimateKey {
        EstimateKey(url: sourceURL, isLoaded: info != nil, request: request)
    }

    /// The estimate if it belongs to the current settings.
    var currentEstimate: SizeEstimate? {
        estimate?.request == request ? estimate : nil
    }

    /// Export always goes through Convert, where format, metadata and
    /// quality are chosen: from any other tool it switches there first.
    func export() {
        if tool == .convert {
            presentSavePanel()
        } else {
            tool = .convert
        }
    }

    /// Decodes the full-resolution image, oriented as displayed, so the
    /// loupe shows real pixels rather than the down-sampled preview.
    func prepareLoupe() {
        guard let sourceURL, let info else { return }
        let orientation = Orientation(exif: info.orientation).followed(by: geometry.orientation)
        guard loupeImage?.orientation != orientation || loupeImage?.url != sourceURL else { return }
        loupeTask?.cancel()
        loupeTask = Task {
            guard let image = try? await ImageEngine.displayImage(url: sourceURL, orientation: orientation.exif),
                  !Task.isCancelled, self.sourceURL == sourceURL
            else { return }
            loupeImage = LoupeImage(url: sourceURL, orientation: orientation, image: image)
        }
    }

    /// Opens the Save panel directly. Losses are listed in the Convert panel
    /// and repeated in the Save panel's message, so the user is told before
    /// anything is written, without stacking dialogs (a confirmation dialog
    /// closing while the Save sheet opened made the sheet vanish).
    func presentSavePanel() {
        guard let sourceURL, let plan, !isExporting else { return }
        let panel = NSSavePanel()
        let format = plan.request.target
        panel.nameFieldStringValue = SafeOutput.defaultDestination(
            for: sourceURL, pathExtension: format.preferredFileExtension
        ).lastPathComponent
        panel.directoryURL = sourceURL.deletingLastPathComponent()
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

    /// Clears the "Saved…" / error message.
    func dismissExportStatus() {
        if !isExporting { exportState = .idle }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

struct CropDrag: Equatable {
    var handle: CropHandle
    var rect: PixelRect
}

struct LoupeImage {
    let url: URL
    let orientation: Orientation
    let image: PreviewImage
}

struct EstimateKey: Equatable {
    let url: URL?
    let isLoaded: Bool
    let request: ConvertRequest
}

struct SizeEstimate: Equatable {
    let request: ConvertRequest
    /// nil while measuring or after a failure.
    let bytes: Int64?
    var failure: String? = nil
}

enum ComposeMode: String, CaseIterable, Identifiable {
    case layers, horizontal, vertical, grid

    var id: Self { self }

    var title: String {
        switch self {
        case .layers: "On top"
        case .horizontal: "Side by side"
        case .vertical: "Stacked"
        case .grid: "Grid"
        }
    }

    var symbol: String {
        switch self {
        case .layers: "square.on.square"
        case .horizontal: "rectangle.split.2x1"
        case .vertical: "rectangle.split.1x2"
        case .grid: "square.grid.2x2"
        }
    }
}

