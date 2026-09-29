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

    // MARK: PDF state
    /// The open file is a PDF (PDF → images); otherwise PDF means images → PDF.
    private(set) var isPDFDocument = false
    private(set) var pdfInfo: PDFInfo?
    var needsPDFPassword = false
    var pdfPasswordError: String?
    @ObservationIgnored private var pdfPassword: String?
    private(set) var pageThumbnails: [Int: PDFEngine.CGImageBox] = [:]
    var selectedPages: Set<Int> = []
    var rasterDPI: Double = 150
    var rasterFormat: ImageFormat = .png
    var rasterQuality: Double = 0.9
    var pdfPageSize: PDFEngine.PageSize = .fitImage
    var pdfMargin: Double = 36
    /// nil = best (JPEG pages untouched); a value = every page JPEG at it.
    var pdfImageQuality: Double?
    private(set) var pdfEstimate: (key: PDFEstimateKey, bytes: Int64?)?
    /// The pages of the PDF that would be saved, rendered small.
    private(set) var pdfPreviewPages: [PDFEngine.CGImageBox] = []
    @ObservationIgnored private var pdfPreviewFolder: URL?
    /// Extra pages after the opened image for Images → PDF.
    var pdfImages: [ComposedImage] = []

    // MARK: Compose state
    var composeMode: ComposeMode = .layers
    var layers: [OverlayLayer] = []
    var arrangedImages: [ComposedImage] = []
    var spacing = 0
    var sizing: Arrangement.Sizing = .matchSmallest
    var alignment: Arrangement.Alignment = .center
    var background: Arrangement.Background = .white
    var gridColumns = 2
    /// Where the opened image sits among the arranged images.
    var basePosition = 0
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
                           alignment: alignment, background: background, basePosition: basePosition)
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

    /// All arranged images in order, the opened one included (nil).
    var arrangementOrder: [ComposedImage?] {
        arrangement.ordered(base: nil, others: arrangedImages.map { Optional($0) })
    }

    /// Most columns a grid can usefully have: one per image.
    var maxGridColumns: Int { max(arrangedImages.count + 1, 2) }

    /// Moves the item at `index` of `arrangementOrder` (the opened image
    /// or an added one) by `offset`.
    func moveArranged(at index: Int, by offset: Int) {
        var order = arrangementOrder
        let target = index + offset
        guard order.indices.contains(index), order.indices.contains(target) else { return }
        order.swapAt(index, target)
        basePosition = order.firstIndex { $0 == nil } ?? 0
        arrangedImages = order.compactMap { $0 }
    }

    func removeImage(_ image: ComposedImage) {
        layers.removeAll { $0.image == image }
        if let index = arrangedImages.firstIndex(of: image), index < basePosition { basePosition -= 1 }
        arrangedImages.removeAll { $0 == image }
        basePosition = min(basePosition, arrangedImages.count)
        gridColumns = min(gridColumns, maxGridColumns)
        if accessedExtras.remove(image.url) != nil { image.url.stopAccessingSecurityScopedResource() }
        extraPreviews[image.url] = nil
    }

    /// Moves a layer earlier (further down) or later (on top).
    func moveLayer(at index: Int, by offset: Int) {
        let target = index + offset
        guard layers.indices.contains(index), layers.indices.contains(target) else { return }
        layers.swapAt(index, target)
    }

    /// Switching between layers and arrangements carries the images over.
    func setComposeMode(_ mode: ComposeMode) {
        let images = composedImages
        let wasLayers = composeMode == .layers
        composeMode = mode
        if wasLayers && mode != .layers {
            arrangedImages = images
            basePosition = 0
        } else if !wasLayers && mode == .layers {
            let canvas = croppedSize ?? PixelSize(width: 1, height: 1)
            layers = images.map { OverlayLayer.placed($0, on: canvas) }
            selectedLayerID = layers.last?.id
        }
        gridColumns = min(gridColumns, maxGridColumns)
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
        pdfImages = []
        basePosition = 0
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
        panel.allowedContentTypes = [.image, .pdf]
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
        isPDFDocument = false
        pdfInfo = nil
        pdfPassword = nil
        pdfPasswordError = nil
        needsPDFPassword = false
        pageThumbnails = [:]
        selectedPages = []
        pdfPreviewPages = []
        pdfEstimate = nil
        isLoading = true

        if PDFEngine.isPDF(url) {
            isPDFDocument = true
            tool = .pdf
            await loadPDF(url)
            return
        }

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

    // MARK: - PDF → images

    private func loadPDF(_ url: URL) async {
        let password = pdfPassword
        do {
            let info = try await Task.detached { try PDFEngine.info(url: url, password: password) }.value
            guard sourceURL == url else { return }
            pdfInfo = info
            needsPDFPassword = false
            selectedPages = Set(1...info.pageCount)
            isLoading = false
            // Thumbnails about 320 px on the long side, page by page.
            for page in 1...min(info.pageCount, 500) {
                let size = info.pageSizes[page - 1]
                let dpi = 72 * 320 / max(size.width, size.height, 1)
                guard let image = try? await Task.detached(operation: {
                    PDFEngine.CGImageBox(try PDFEngine.renderPage(url: url, page: page, dpi: dpi, password: password))
                }).value, sourceURL == url else { continue }
                pageThumbnails[page] = image
            }
        } catch PDFError.locked {
            needsPDFPassword = true
            isLoading = false
        } catch PDFError.wrongPassword {
            pdfPasswordError = "That password didn't work. Try again."
            needsPDFPassword = true
            isLoading = false
        } catch {
            loadError = String(describing: error)
            isLoading = false
        }
    }

    func unlockPDF(with password: String) {
        guard let sourceURL else { return }
        pdfPassword = password
        pdfPasswordError = nil
        needsPDFPassword = false
        isLoading = true
        Task { await loadPDF(sourceURL) }
    }

    func togglePage(_ page: Int) {
        if selectedPages.contains(page) { selectedPages.remove(page) } else { selectedPages.insert(page) }
    }

    func exportPagesToFolder() {
        guard let sourceURL, !selectedPages.isEmpty, !isExporting else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for \(selectedPages.count) page image\(selectedPages.count == 1 ? "" : "s")."
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let pages = selectedPages.sorted()
        let (dpi, format, password) = (rasterDPI, rasterFormat, pdfPassword)
        let quality = format.hasLossyMode ? (format == .webp && rasterQuality >= 0.99 ? nil : rasterQuality) : nil
        exportState = .running(0)
        exportTask = Task {
            let accessed = folder.startAccessingSecurityScopedResource()
            defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
            do {
                let files = try await PDFEngine.exportPages(
                    url: sourceURL, pages: pages, dpi: dpi, format: format, lossyQuality: quality,
                    to: folder, password: password
                ) { fraction in
                    Task { @MainActor in
                        guard case .running = self.exportState else { return }
                        self.exportState = .running(fraction)
                    }
                }
                exportState = .saved(files.first ?? folder)
            } catch is CancellationError {
                exportState = .idle
            } catch {
                exportState = .failed(String(describing: error))
            }
        }
    }

    // MARK: - Images → PDF

    func addPDFImages(_ urls: [URL]) async {
        for url in urls where url != sourceURL && !pdfImages.contains(where: { $0.url == url }) {
            if url.startAccessingSecurityScopedResource() { accessedExtras.insert(url) }
            guard let info = try? await ImageEngine.inspectAsync(url: url) else {
                composeWarning = "“\(url.lastPathComponent)” couldn't be read as an image."
                continue
            }
            pdfImages.append(ComposedImage(url: url, info: info))
            if extraPreviews[url] == nil, let preview = try? await ImageEngine.preview(url: url, maxPixelSize: 1024) {
                extraPreviews[url] = preview
            }
        }
    }

    func presentAddPDFImagesPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await addPDFImages(urls) }
    }

    func movePDFImage(at index: Int, by offset: Int) {
        let target = index + offset
        guard pdfImages.indices.contains(index), pdfImages.indices.contains(target) else { return }
        pdfImages.swapAt(index, target)
    }

    /// Turns the images combined in Compose into pages of their own.
    func splitCompositionIntoPages() {
        let images = composedImages
        layers = []
        arrangedImages = []
        basePosition = 0
        selectedLayerID = nil
        pdfImages = images + pdfImages.filter { !images.contains($0) }
    }

    func removePDFImage(_ image: ComposedImage) {
        pdfImages.removeAll { $0 == image }
    }

    func presentPDFSavePanel() {
        guard let sourceURL, !isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = SafeOutput.defaultDestination(for: sourceURL, pathExtension: "pdf").lastPathComponent
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let pages = pdfImages.count + 1
        let size = pdfEstimate?.bytes.map { " · ≈ " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        panel.message = "\(pages) page\(pages == 1 ? "" : "s")\(size)"
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            MainActor.assumeIsolated { self?.startPDFExport(to: destination) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    private func startPDFExport(to destination: URL) {
        guard let sourceURL else { return }
        // The opened image goes in as edited (crop, rotate, compose…);
        // untouched, it's passed as the file so JPEGs aren't re-encoded.
        let editedPlan = (hasEdits || composition != nil) ? plan : nil
        let extras = pdfImages.map { PDFEngine.PageImage(url: $0.url) }
        let (pageSize, margin, imageQuality) = (pdfPageSize, pdfMargin, pdfImageQuality)
        let title = sourceURL.deletingPathExtension().lastPathComponent
        exportState = .running(0)
        exportTask = Task {
            do {
                var first = PDFEngine.PageImage(url: sourceURL)
                if let editedPlan { first.rendered = try await PDFEngine.renderedPage(sourceURL, plan: editedPlan) }
                try await PDFEngine.makePDF(
                    from: [first] + extras, pageSize: pageSize, margin: margin, title: title,
                    imageQuality: imageQuality, to: destination, overwrite: true
                ) { fraction in
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

    var pdfEstimateKey: PDFEstimateKey {
        PDFEstimateKey(source: sourceURL, pages: pdfImages.map(\.url), pageSize: pdfPageSize, margin: pdfMargin,
                       quality: pdfImageQuality, request: (hasEdits || composition != nil) ? request : nil)
    }

    /// Measures the PDF by building it in a temporary folder.
    func refreshPDFEstimate() async {
        guard let sourceURL, !isPDFDocument, info != nil else { return }
        let key = pdfEstimateKey
        pdfEstimate = (key, nil)
        do {
            try await Task.sleep(for: .milliseconds(400))
            var first = PDFEngine.PageImage(url: sourceURL)
            if key.request != nil, let plan { first.rendered = try await PDFEngine.renderedPage(sourceURL, plan: plan) }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dex-pdf-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let output = folder.appendingPathComponent("preview.pdf")
            try await PDFEngine.makePDF(from: [first] + key.pages.map { PDFEngine.PageImage(url: $0) },
                                        pageSize: key.pageSize, margin: key.margin, title: "preview",
                                        imageQuality: key.quality, to: output)
            guard pdfEstimateKey == key else { try? FileManager.default.removeItem(at: folder); return }
            let bytes = Int64(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            pdfEstimate = (key, bytes)
            // The same PDF becomes the preview: exactly what will be saved.
            let pages = try await Task.detached { () -> [PDFEngine.CGImageBox] in
                let info = try PDFEngine.info(url: output)
                return try (1...info.pageCount).map { page in
                    let size = info.pageSizes[page - 1]
                    return PDFEngine.CGImageBox(try PDFEngine.renderPage(url: output, page: page, dpi: 72 * 900 / max(size.width, size.height, 1)))
                }
            }.value
            if let old = pdfPreviewFolder { try? FileManager.default.removeItem(at: old) }
            pdfPreviewFolder = folder
            if pdfEstimateKey == key { pdfPreviewPages = pages }
        } catch {}
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

    /// The loupe's full-resolution pixels are only needed while cropping.
    func releaseLoupe() {
        loupeTask?.cancel()
        loupeTask = nil
        loupeImage = nil
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


struct PDFEstimateKey: Equatable {
    let source: URL?
    let pages: [URL]
    let pageSize: PDFEngine.PageSize
    let margin: Double
    let quality: Double?
    let request: ConvertRequest?
}

