import AppKit
import AudioEngine
import ImageEngine
import JobSystem
import MediaModel
import Observation
import PDFKit
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
    /// Set when the open file is audio; the audio workspace takes over.
    private(set) var audio: AudioDocument?
    /// YouTube link → audio in Downloads.
    let linkDownload = LinkDownload()
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
    /// The Fit background last chosen, kept while switching back to Crop.
    var fitBackground: Framing.Background = .white
    /// Lossless compression (Compress → Lossless).
    var optimize = false

    // MARK: PDF state
    /// The open file is a PDF (PDF → images); otherwise PDF means images → PDF.
    private(set) var isPDFDocument = false
    private(set) var pdfInfo: PDFInfo?
    var needsPDFPassword = false
    var pdfPasswordError: String?
    @ObservationIgnored private var pdfPassword: String?
    /// The open PDF being edited (PDFKit isn't Sendable: main actor only).
    @ObservationIgnored private(set) var pdfEditor: PDFEditor?
    /// Bumped after every edit so views re-read the pages.
    private(set) var pdfRevision = 0
    private(set) var pdfEdited = false
    var pdfMode: PDFMode = .edit
    /// Selected pages by identity, so selection survives reordering.
    var selectedPageIDs: Set<ObjectIdentifier> = []
    var pdfCompression: PDFEditor.Compression = .none
    private(set) var editedPDFEstimate: (key: String, bytes: Int64?)?
    var pdfText = ""
    var pdfTextSize: Double = 18
    var pdfTextColor: PDFTextColor = .black
    var pdfTextPosition: PDFEditor.TextPosition = .bottomRight
    var splitMode: SplitMode = .everyPage
    var splitEvery = 2
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
    /// Convert saves a PDF instead of an image (PDF isn't an ImageFormat).
    var exportAsPDF = false
    /// The name exports are saved under (no extension); nil = the file's own.
    var outputName: String?
    /// While dragging on a canvas: the item is snapped to the page's centre.
    var centreGuides = CentreGuides()

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
    /// Canvas: the page size, where the opened image sits on it, and its
    /// place among the layers (0 = bottom).
    private(set) var canvasSize = PixelSize(width: 1080, height: 1080)
    var basePlacement = LayerPlacement(centerX: 540, centerY: 540, width: 1080)
    var canvasBasePosition = 0
    /// The opened image is the selected item on the canvas.
    var isBaseSelected = false
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

    /// Size after cropping, before framing and resizing.
    var croppedSize: PixelSize? { effectiveCrop?.size ?? displaySize }

    /// Size after cropping and Fit, before resizing.
    var framedSize: PixelSize? {
        guard let croppedSize else { return nil }
        return geometry.frame.map { $0.canvas(for: croppedSize).canvas } ?? croppedSize
    }

    // MARK: Crop subject

    /// The added image the Crop tool works on: the one selected in Compose.
    /// nil means the opened photo.
    var cropLayer: OverlayLayer? {
        guard composeMode.isLayered, !isBaseSelected, let id = selectedLayerID else { return nil }
        return layers.first { $0.id == id }
    }

    /// Each added image remembers its own ratio choice.
    var layerAspects: [UUID: CropAspect] = [:]

    /// Upright size of what Crop works on.
    var subjectDisplaySize: PixelSize? { cropLayer?.image.info.displaySize ?? displaySize }

    var subjectCrop: PixelRect? { cropLayer.map { $0.crop } ?? effectiveCrop }

    var subjectFrame: Framing? { cropLayer.map { $0.frame } ?? geometry.frame }

    var subjectAspect: CropAspect { cropLayer.map { layerAspects[$0.id] ?? .free } ?? cropAspect }

    var isFitting: Bool { subjectFrame != nil }

    var subjectHasEdits: Bool {
        cropLayer.map { $0.crop != nil || $0.frame != nil } ?? hasEdits
    }

    func setSubjectCrop(_ rect: PixelRect?) {
        if let layer = cropLayer { editLayer(layer.id) { $0.crop = rect } } else { geometry.crop = rect }
    }

    private func setSubjectFrame(_ frame: Framing?) {
        if let layer = cropLayer { editLayer(layer.id) { $0.frame = frame } } else { geometry.frame = frame }
    }

    /// Changes a layer's crop or Fit while keeping its pixels at the same
    /// size on the canvas, so the picture doesn't jump.
    private func editLayer(_ id: UUID, _ change: (inout OverlayLayer) -> Void) {
        updateLayer(id) { layer in
            let old = layer.editedSize
            change(&layer)
            layer.width = max((layer.width * Double(layer.editedSize.width) / Double(max(old.width, 1))).rounded(), 1)
        }
    }

    /// Chooses a ratio: a centred crop of it, or in Fit, a canvas of it.
    func setCropAspect(_ aspect: CropAspect) {
        if let layer = cropLayer { layerAspects[layer.id] = aspect } else { cropAspect = aspect; geometry.resize = nil }
        guard let ratio = aspect.ratio else {
            setSubjectFrame(nil)
            return
        }
        if isFitting {
            setSubjectFrame(Framing(ratio: ratio, background: fitBackground))
        } else if let display = subjectDisplaySize {
            setSubjectCrop(CropMath.centred(ratio: ratio, in: display))
        }
    }

    /// Crop cuts the picture to the ratio; Fit keeps all of it and adds
    /// background around it.
    func setFitting(_ fit: Bool) {
        guard let ratio = subjectAspect.ratio, fit != isFitting else { return }
        if cropLayer == nil { geometry.resize = nil }
        if fit {
            setSubjectCrop(nil)
            setSubjectFrame(Framing(ratio: ratio, background: fitBackground))
        } else {
            setSubjectFrame(nil)
            if let display = subjectDisplaySize { setSubjectCrop(CropMath.centred(ratio: ratio, in: display)) }
        }
    }

    func setFitBackground(_ background: Framing.Background) {
        fitBackground = background
        if var frame = subjectFrame {
            frame.background = background
            setSubjectFrame(frame)
        }
    }

    /// Undoes the crop, Fit and rotation of whatever Crop is working on.
    func resetSubject() {
        if let layer = cropLayer {
            layerAspects[layer.id] = nil
            editLayer(layer.id) { $0.crop = nil; $0.frame = nil; $0.rotation = 0 }
        } else {
            resetGeometry()
            cropAspect = .free
        }
    }

    /// Rotates whatever Crop is working on; added images turn on the canvas.
    func rotateSubject(clockwise: Bool) {
        if let layer = cropLayer {
            updateLayer(layer.id) { $0.rotation = (($0.rotation + (clockwise ? 90 : -90) + 540).truncatingRemainder(dividingBy: 360)) - 180 }
        } else if clockwise {
            rotateClockwise()
        } else {
            rotateCounterclockwise()
        }
    }

    var hasEdits: Bool { !geometry.isIdentity }

    // MARK: Compose

    var composition: Composition? {
        switch composeMode {
        case .layers:
            return layers.isEmpty ? nil : .layers(layers)
        case .horizontal, .vertical, .grid:
            return arrangedImages.isEmpty ? nil : .arrangement(arrangement)
        case .canvas:
            return .canvas(canvas)
        }
    }

    /// A4 at 300 dpi: where a new canvas starts.
    static let a4 = PixelSize(width: 2480, height: 3508)

    var canvas: Canvas {
        Canvas(size: canvasSize, background: background, base: basePlacement, layers: layers,
               basePosition: canvasBasePosition)
    }

    /// What layers are placed on: the page in Canvas, otherwise the photo.
    var layerCanvasSize: PixelSize? { composeMode == .canvas ? canvasSize : framedSize }

    /// A new page size: the opened image is fitted again, layers keep
    /// their place in proportion.
    func setCanvasSize(_ size: PixelSize) {
        let size = PixelSize(width: min(max(size.width, 16), 16_000), height: min(max(size.height, 16), 16_000))
        let old = canvasSize
        canvasSize = size
        if let base = framedSize { basePlacement = .fitted(base, on: size) }
        for index in layers.indices { layers[index].placement = layers[index].placement.moved(from: old, to: size) }
    }

    /// Canvas items bottom to top: nil is the opened image.
    var canvasOrder: [UUID?] {
        var order: [UUID?] = layers.map(\.id)
        order.insert(nil, at: min(max(canvasBasePosition, 0), layers.count))
        return order
    }

    /// Moves a canvas item (the opened image or a layer) down or up.
    func moveCanvasItem(at index: Int, by offset: Int) {
        var order = canvasOrder
        let target = index + offset
        guard order.indices.contains(index), order.indices.contains(target) else { return }
        order.swapAt(index, target)
        canvasBasePosition = order.firstIndex { $0 == nil } ?? 0
        let byID = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
        layers = order.compactMap { $0.flatMap { byID[$0] } }
    }

    func updateBase(_ change: (inout LayerPlacement) -> Void) {
        change(&basePlacement)
    }

    func selectLayer(_ id: UUID?) {
        selectedLayerID = id
        isBaseSelected = false
    }

    func selectBase() {
        selectedLayerID = nil
        isBaseSelected = true
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
        composeMode.isLayered ? layers.map(\.image) : arrangedImages
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
            if composeMode.isLayered {
                let layer = OverlayLayer.placed(image, on: layerCanvasSize ?? info.displaySize)
                layers.append(layer)
                selectLayer(layer.id)
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
        if let index = layers.firstIndex(where: { $0.image == image }), index < canvasBasePosition { canvasBasePosition -= 1 }
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

    /// Switching modes carries the images over. Canvas starts as a page
    /// the size of the photo, with the photo filling it.
    func setComposeMode(_ mode: ComposeMode) {
        guard mode != composeMode else { return }
        let images = composedImages
        let wasLayered = composeMode.isLayered
        let oldCanvas = layerCanvasSize
        if mode == .canvas, let base = framedSize {
            canvasSize = Self.a4
            basePlacement = .fitted(base, on: Self.a4)
            canvasBasePosition = 0
        }
        composeMode = mode
        isBaseSelected = false
        if wasLayered && !mode.isLayered {
            arrangedImages = images
            basePosition = 0
        } else if !wasLayered && mode.isLayered {
            let canvas = layerCanvasSize ?? PixelSize(width: 1, height: 1)
            layers = images.map { OverlayLayer.placed($0, on: canvas) }
            selectedLayerID = layers.last?.id
        } else if let oldCanvas, let canvas = layerCanvasSize, oldCanvas != canvas {
            for index in layers.indices { layers[index].placement = layers[index].placement.moved(from: oldCanvas, to: canvas) }
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
        composeMode = .layers
        canvasBasePosition = 0
        isBaseSelected = false
        layerAspects = [:]
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

    var canExport: Bool { audio.map(\.canExport) ?? (plan != nil && !isExporting) }

    // MARK: - Opening

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf, .audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await open(url) }
    }

    func open(_ url: URL) async {
        reset()
        accessedURL = url.startAccessingSecurityScopedResource() ? url : nil
        sourceURL = url
        isLoading = true

        if AudioEngine.isAudio(url) {
            let audio = AudioDocument(url: url)
            self.audio = audio
            isLoading = false
            await audio.load()
            return
        }

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

    /// The export name without extension: the chosen one or the file's own.
    var exportBaseName: String {
        outputName ?? sourceURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    func renameOutput(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        outputName = trimmed.isEmpty || trimmed == sourceURL?.deletingPathExtension().lastPathComponent ? nil : trimmed
    }

    /// Stands in for the source when naming a new file, so save panels
    /// suggest the chosen name (with " 2" etc. if it's taken).
    private func namingURL(_ source: URL) -> URL {
        source.deletingLastPathComponent().appendingPathComponent(exportBaseName).appendingPathExtension(source.pathExtension)
    }

    /// Closes the open file and returns to the drop zone.
    func goHome() {
        reset()
        tool = .convert
        isLoading = false
    }

    /// Forgets everything about the open file, as if nothing were open.
    private func reset() {
        exportTask?.cancel()
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        sourceURL = nil
        audio?.close()
        audio = nil
        info = nil
        preview = nil
        releaseExtras()
        geometry = Geometry()
        cropAspect = .free
        fitBackground = .white
        exportAsPDF = false
        outputName = nil
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
        pdfEditor = nil
        pdfEdited = false
        pdfRevision = 0
        selectedPageIDs = []
        editedPDFEstimate = nil
        pdfMode = .edit
        pdfPreviewPages = []
        pdfEstimate = nil
    }

    // MARK: - PDF → images

    private func loadPDF(_ url: URL) async {
        do {
            let editor = try PDFEditor(url: url, password: pdfPassword)
            guard sourceURL == url else { return }
            pdfEditor = editor
            pdfEdited = false
            needsPDFPassword = false
            refreshPDFInfo()
            selectedPageIDs = []
            isLoading = false
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

    // MARK: - PDF editing

    /// Pages in order; reading `pdfRevision` makes views update after edits.
    var pdfPages: [PDFPage] {
        _ = pdfRevision
        guard let pdfEditor else { return [] }
        return (0..<pdfEditor.pageCount).compactMap { pdfEditor.page($0) }
    }

    var selectedIndices: [Int] {
        pdfPages.enumerated().filter { selectedPageIDs.contains(ObjectIdentifier($0.element)) }.map(\.offset)
    }

    func togglePage(_ page: PDFPage) {
        let id = ObjectIdentifier(page)
        if selectedPageIDs.contains(id) { selectedPageIDs.remove(id) } else { selectedPageIDs.insert(id) }
    }

    func selectAllPages() { selectedPageIDs = Set(pdfPages.map(ObjectIdentifier.init)) }
    func selectNoPages() { selectedPageIDs = [] }

    private func pdfChanged() {
        pdfEdited = true
        pdfRevision += 1
        refreshPDFInfo()
        let alive = Set(pdfPages.map(ObjectIdentifier.init))
        selectedPageIDs = selectedPageIDs.intersection(alive)
    }

    private func refreshPDFInfo() {
        guard let pdfEditor, let sourceURL else { return }
        let size = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        pdfInfo = PDFInfo(fileName: sourceURL.lastPathComponent, fileSize: size, pageCount: pdfEditor.pageCount,
                          pageSizes: pdfEditor.pageSizes, isEncrypted: pdfEditor.document.isEncrypted)
    }

    func rotateSelectedPages(clockwise: Bool) {
        pdfEditor?.rotate(selectedIndices, quarterTurns: clockwise ? 1 : -1)
        pdfChanged()
    }

    func deleteSelectedPages() {
        guard let pdfEditor, selectedIndices.count < pdfEditor.pageCount else { return }
        pdfEditor.delete(selectedIndices)
        pdfChanged()
    }

    /// Moves the selection one place earlier (-1) or later (+1).
    func moveSelectedPages(by offset: Int) {
        let indices = selectedIndices
        guard let first = indices.first, let last = indices.last, let pdfEditor else { return }
        let destination = offset < 0 ? first - 1 : last + 2 - indices.count
        guard destination >= 0, destination + indices.count <= pdfEditor.pageCount else { return }
        pdfEditor.movePages(indices, to: destination)
        pdfChanged()
    }

    /// Drag and drop: puts the dragged page (or the whole selection, if the
    /// dragged page is selected) before `target`.
    func dropPage(_ dragged: Int, before target: Int) {
        guard let pdfEditor else { return }
        let draggedPage = pdfEditor.page(dragged).map(ObjectIdentifier.init)
        let moving = draggedPage.map(selectedPageIDs.contains) == true ? selectedIndices : [dragged]
        let before = moving.filter { $0 < target }.count
        pdfEditor.movePages(moving, to: max(target - before, 0))
        pdfChanged()
    }

    private var insertionIndex: Int? { selectedIndices.last.map { $0 + 1 } }

    func presentAddPDFPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Choose PDFs to add after the selected page (or at the end)."
        guard panel.runModal() == .OK, let pdfEditor else { return }
        var position = insertionIndex ?? pdfEditor.pageCount
        for url in panel.urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                position += try pdfEditor.insertPDF(url, at: position)
            } catch {
                exportState = .failed(String(describing: error))
            }
        }
        pdfChanged()
    }

    func presentAddImagePagesPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images to add as pages. Any format works."
        guard panel.runModal() == .OK, let pdfEditor else { return }
        var position = insertionIndex ?? pdfEditor.pageCount
        for url in panel.urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                try pdfEditor.insertImage(url, at: position)
                position += 1
            } catch {
                exportState = .failed(String(describing: error))
            }
        }
        pdfChanged()
    }

    func addTextToSelectedPage() {
        guard let index = selectedIndices.first, !pdfText.isEmpty else { return }
        pdfEditor?.addText(pdfText, page: index, position: pdfTextPosition, fontSize: pdfTextSize, color: pdfTextColor.color)
        pdfText = ""
        pdfChanged()
    }

    func revertPDF() {
        guard let sourceURL else { return }
        Task { await loadPDF(sourceURL) }
    }

    /// Measures the edited PDF at the chosen compression.
    var editedEstimateKey: String { "\(pdfRevision)-\(pdfCompression.rawValue)" }

    func refreshEditedPDFEstimate() async {
        guard let pdfEditor else { return }
        let key = editedEstimateKey
        editedPDFEstimate = (key, nil)
        try? await Task.sleep(for: .milliseconds(300))
        guard editedEstimateKey == key, let data = pdfEditor.snapshot() else { return }
        let compression = pdfCompression
        guard let bytes = try? await PDFEditor.compress(data, compression).count, editedEstimateKey == key else { return }
        editedPDFEstimate = (key, Int64(bytes))
    }

    func presentSaveEditedPDFPanel(selectedOnly: Bool = false) {
        guard let sourceURL, let pdfEditor, !isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let suffix = selectedOnly ? " (pages)" : " (edited)"
        panel.nameFieldStringValue = SafeOutput.defaultDestination(
            for: sourceURL.deletingLastPathComponent().appendingPathComponent(base + suffix).appendingPathExtension("pdf"),
            pathExtension: "pdf"
        ).lastPathComponent
        let pages = selectedOnly ? selectedIndices.count : pdfEditor.pageCount
        panel.message = "\(pages) page\(pages == 1 ? "" : "s"). The original PDF is never changed."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let data = selectedOnly ? pdfEditor.extract(selectedIndices).dataRepresentation() : pdfEditor.snapshot()
        guard let data else { return }
        let compression = pdfCompression
        exportState = .running(0.3)
        exportTask = Task {
            do {
                let output = try await PDFEditor.compress(data, compression)
                try PDFEditor.save(output, to: destination, source: sourceURL, overwrite: true)
                exportState = .saved(destination)
            } catch {
                exportState = .failed(String(describing: error))
            }
        }
    }

    func splitToFolder() {
        guard let sourceURL, let pdfEditor, !isExporting else { return }
        let parts: [PDFDocument] = switch splitMode {
        case .everyPage: pdfEditor.split(every: 1)
        case .everyN: pdfEditor.split(every: splitEvery)
        case .atSelection: pdfEditor.split(before: selectedIndices)
        }
        guard parts.count > 1 else {
            exportState = .failed("That split makes only one part. Select the pages where new parts should start.")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Split Here"
        panel.message = "Choose a folder for \(parts.count) PDFs."
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        let base = sourceURL.deletingPathExtension().lastPathComponent
        var written: [URL] = []
        do {
            for (index, part) in parts.enumerated() {
                let name = "\(base) part \(index + 1)"
                let destination = SafeOutput.defaultDestination(
                    for: folder.appendingPathComponent(name).appendingPathExtension("pdf"), pathExtension: "pdf"
                )
                try PDFEditor.save(part, to: destination, source: sourceURL)
                written.append(destination)
            }
            exportState = .saved(written[0])
        } catch {
            exportState = .failed(String(describing: error))
        }
    }

    /// Pages to export as images: the selection, or every page if none.
    var pagesToExport: [Int] {
        selectedIndices.isEmpty ? Array(0..<(pdfEditor?.pageCount ?? 0)) : selectedIndices
    }

    func exportPagesToFolder() {
        guard let sourceURL, let pdfEditor, !pagesToExport.isEmpty, !isExporting else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for \(pagesToExport.count) page image\(pagesToExport.count == 1 ? "" : "s")."
        panel.directoryURL = sourceURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let pages = pagesToExport.map { $0 + 1 }
        let (dpi, format) = (rasterDPI, rasterFormat)
        let quality = format.hasLossyMode ? (format == .webp && rasterQuality >= 0.99 ? nil : rasterQuality) : nil
        // Export from the document as edited (rotations, order…), written
        // to a temporary file under the original's name.
        guard let data = pdfEditor.snapshot() else { return }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("dex-\(UUID().uuidString)", isDirectory: true)
        let edited = scratch.appendingPathComponent(sourceURL.lastPathComponent)
        exportState = .running(0)
        exportTask = Task {
            let accessed = folder.startAccessingSecurityScopedResource()
            defer {
                if accessed { folder.stopAccessingSecurityScopedResource() }
                try? FileManager.default.removeItem(at: scratch)
            }
            do {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                try data.write(to: edited)
                let files = try await PDFEngine.exportPages(
                    url: edited, pages: pages, dpi: dpi, format: format, lossyQuality: quality, to: folder
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
        canvasBasePosition = 0
        selectedLayerID = nil
        if composeMode == .canvas { composeMode = .layers }
        pdfImages = images + pdfImages.filter { !images.contains($0) }
    }

    func removePDFImage(_ image: ComposedImage) {
        pdfImages.removeAll { $0 == image }
    }

    func presentPDFSavePanel() {
        guard let sourceURL, !isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = SafeOutput.defaultDestination(for: namingURL(sourceURL), pathExtension: "pdf").lastPathComponent
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
        let (pageSize, margin, imageQuality) = (pdfPageSetup.size, pdfPageSetup.margin, pdfImageQuality)
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

    /// A canvas made at A4 or Letter size (300 dpi), if there is one.
    var canvasPaper: (title: String, size: PDFEngine.PageSize)? {
        guard composeMode == .canvas else { return nil }
        switch (canvasSize.width, canvasSize.height) {
        case (2480, 3508), (3508, 2480): return ("A4", .a4)
        case (2550, 3300), (3300, 2550): return ("Letter", .letter)
        default: return nil
        }
    }

    /// Page size and margin for Images → PDF: a paper-sized canvas is
    /// that paper with no margin, so it prints at true size.
    var pdfPageSetup: (size: PDFEngine.PageSize, margin: Double) {
        canvasPaper.map { ($0.size, 0) } ?? (pdfPageSize, pdfMargin)
    }

    var pdfEstimateKey: PDFEstimateKey {
        PDFEstimateKey(source: sourceURL, pages: pdfImages.map(\.url), pageSize: pdfPageSetup.size, margin: pdfPageSetup.margin,
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
        if let audio {
            audio.export()
        } else if tool == .convert {
            if exportAsPDF { presentPDFSavePanel() } else { presentSavePanel() }
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
            for: namingURL(sourceURL), pathExtension: format.preferredFileExtension
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

struct CentreGuides: Equatable {
    var vertical = false
    var horizontal = false
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
    case layers, horizontal, vertical, grid, canvas

    var id: Self { self }

    /// Images are placed freely (moved, scaled, turned) rather than laid out.
    var isLayered: Bool { self == .layers || self == .canvas }

    var title: String {
        switch self {
        case .layers: "On top"
        case .horizontal: "Side by side"
        case .vertical: "Stacked"
        case .grid: "Grid"
        case .canvas: "Canvas"
        }
    }

    var symbol: String {
        switch self {
        case .layers: "square.on.square"
        case .horizontal: "rectangle.split.2x1"
        case .vertical: "rectangle.split.1x2"
        case .grid: "square.grid.2x2"
        case .canvas: "rectangle.on.rectangle.angled"
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


enum PDFMode: String, CaseIterable, Identifiable {
    case edit, images
    var id: Self { self }
}

enum SplitMode: String, CaseIterable, Identifiable {
    case everyPage, everyN, atSelection
    var id: Self { self }
}

enum PDFTextColor: String, CaseIterable, Identifiable {
    case black, white, red, ember
    var id: Self { self }

    var color: NSColor {
        switch self {
        case .black: .black
        case .white: .white
        case .red: .systemRed
        case .ember: NSColor(red: 0.96, green: 0.36, blue: 0.15, alpha: 1)
        }
    }
}
