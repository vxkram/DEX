import AppKit
import Foundation
import JobSystem
import MediaModel
import PDFKit
import Quartz

/// Page-level PDF editing on top of PDFKit, so text and vector content stay
/// intact (nothing is rasterised). Pages are 0-based here.
///
/// PDFKit documents aren't thread-safe; use an editor from one actor (the
/// UI's main actor) and hand `snapshot()` data to background work.
public final class PDFEditor {
    public private(set) var document: PDFDocument
    public let sourceURL: URL

    public init(url: URL, password: String? = nil) throws {
        guard let document = PDFDocument(url: url) else { throw PDFError.unreadable(url.lastPathComponent) }
        if document.isLocked {
            guard let password else { throw PDFError.locked(url.lastPathComponent) }
            guard document.unlock(withPassword: password) else { throw PDFError.wrongPassword }
        }
        self.document = document
        self.sourceURL = url
    }

    public var pageCount: Int { document.pageCount }

    public func page(_ index: Int) -> PDFPage? { document.page(at: index) }

    // MARK: - Pages

    /// Moves a page so it ends up at `destination` (in the order after the move).
    public func movePage(from source: Int, to destination: Int) {
        guard let page = document.page(at: source), (0..<pageCount).contains(destination), source != destination else { return }
        document.removePage(at: source)
        document.insert(page, at: destination)
    }

    /// Moves the given pages together so they start at `destination`,
    /// keeping their relative order.
    public func movePages(_ indices: [Int], to destination: Int) {
        let sorted = indices.sorted().filter { (0..<pageCount).contains($0) }
        let pages = sorted.compactMap { document.page(at: $0) }
        for index in sorted.reversed() { document.removePage(at: index) }
        let target = min(max(destination, 0), pageCount)
        for (offset, page) in pages.enumerated() { document.insert(page, at: target + offset) }
    }

    /// Rotates pages clockwise by multiples of 90°. Lossless: only the
    /// page's /Rotate entry changes.
    public func rotate(_ indices: [Int], quarterTurns: Int) {
        for index in indices {
            guard let page = document.page(at: index) else { continue }
            page.rotation = ((page.rotation + quarterTurns * 90) % 360 + 360) % 360
        }
    }

    public func delete(_ indices: [Int]) {
        for index in indices.sorted(by: >) where (0..<pageCount).contains(index) && pageCount > 1 {
            document.removePage(at: index)
        }
    }

    /// A new document with copies of the given pages, in order.
    public func extract(_ indices: [Int]) -> PDFDocument {
        let output = PDFDocument()
        for index in indices.sorted() {
            guard let copy = document.page(at: index)?.copy() as? PDFPage else { continue }
            output.insert(copy, at: output.pageCount)
        }
        return output
    }

    // MARK: - Combining

    /// Inserts every page of another PDF at `index` (default: the end).
    @discardableResult
    public func insertPDF(_ url: URL, at index: Int? = nil, password: String? = nil) throws -> Int {
        guard let other = PDFDocument(url: url) else { throw PDFError.unreadable(url.lastPathComponent) }
        if other.isLocked {
            guard let password, other.unlock(withPassword: password) else { throw PDFError.locked(url.lastPathComponent) }
        }
        var position = min(index ?? pageCount, pageCount)
        for pageIndex in 0..<other.pageCount {
            guard let page = other.page(at: pageIndex)?.copy() as? PDFPage else { continue }
            document.insert(page, at: position)
            position += 1
        }
        return other.pageCount
    }

    /// Inserts an image of any format as a page sized to the image
    /// (72 pixels per inch), upright, at `index` (default: the end).
    public func insertImage(_ url: URL, at index: Int? = nil) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw ConvertError.unreadable(url.lastPathComponent) }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let image = try PixelOps.orient(ImageEngine.decodedFrame(source, index: 0, name: url.lastPathComponent), orientation)
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        guard let page = PDFPage(image: nsImage, options: [.compressionQuality: 0.9]) else {
            throw ConvertError.encodeFailed(.jpeg, reason: "could not make a page from \(url.lastPathComponent)")
        }
        document.insert(page, at: min(index ?? pageCount, pageCount))
    }

    /// Splits into consecutive groups of `size` pages.
    public func split(every size: Int) -> [PDFDocument] {
        let size = max(size, 1)
        return stride(from: 0, to: pageCount, by: size).map { start in
            extract(Array(start..<min(start + size, pageCount)))
        }
    }

    /// Splits before each of the given pages (0-based), e.g. [3, 7] makes
    /// pages 1–3, 4–7 and 8–end.
    public func split(before starts: [Int]) -> [PDFDocument] {
        let cuts = ([0] + starts.filter { $0 > 0 && $0 < pageCount } + [pageCount]).sorted()
        let unique = cuts.enumerated().filter { $0.offset == 0 || $0.element != cuts[$0.offset - 1] }.map(\.element)
        return zip(unique, unique.dropFirst()).map { extract(Array($0..<$1)) }
    }

    // MARK: - Text

    public enum TextPosition: String, CaseIterable, Sendable {
        case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    }

    /// Adds a text box (a FreeText annotation, which keeps the text
    /// selectable and editable in other PDF apps).
    public func addText(_ text: String, page index: Int, position: TextPosition, fontSize: CGFloat,
                        color: NSColor, margin: CGFloat = 36) {
        guard let page = document.page(at: index), !text.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin], attributes: [.font: font]
        ).size
        let size = NSSize(width: ceil(measured.width) + 12, height: ceil(measured.height) + 8)
        let bounds = page.bounds(for: .cropBox)
        // Positions are as the page is displayed, so account for rotation.
        let shown = page.rotation % 180 == 0 ? bounds.size : NSSize(width: bounds.height, height: bounds.width)
        let column: CGFloat = switch position {
        case .topLeft, .left, .bottomLeft: margin
        case .top, .center, .bottom: (shown.width - size.width) / 2
        default: shown.width - margin - size.width
        }
        let row: CGFloat = switch position {
        case .topLeft, .top, .topRight: shown.height - margin - size.height
        case .left, .center, .right: (shown.height - size.height) / 2
        default: margin
        }
        let rect = displayedRectToPage(NSRect(origin: NSPoint(x: column, y: row), size: size), page: page, bounds: bounds)
        let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = font
        annotation.fontColor = color
        annotation.color = .clear
        annotation.border = PDFBorder()
        annotation.border?.lineWidth = 0
        page.addAnnotation(annotation)
    }

    /// Maps a rect in displayed (rotation-applied) page space to the page's
    /// own coordinate space.
    private func displayedRectToPage(_ rect: NSRect, page: PDFPage, bounds: NSRect) -> NSRect {
        let (w, h) = (bounds.width, bounds.height)
        let r: NSRect = switch page.rotation {
        case 90: NSRect(x: w - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        case 180: NSRect(x: w - rect.maxX, y: h - rect.maxY, width: rect.width, height: rect.height)
        case 270: NSRect(x: rect.minY, y: h - rect.maxX, width: rect.height, height: rect.width)
        default: rect
        }
        return r.offsetBy(dx: bounds.minX, dy: bounds.minY)
    }

    // MARK: - Saving

    public enum Compression: String, CaseIterable, Sendable {
        /// Pages and images exactly as they are.
        case none
        /// Images as JPEG 0.8, at most 200 DPI / 3000 px: hard to tell apart.
        case balanced
        /// Images as JPEG 0.6, at most 144 DPI / 2000 px: for email and web.
        case smallest

        /// A Quartz filter like Preview's "Reduce File Size". Text and
        /// vector graphics stay as they are; only images are re-encoded.
        /// (PDFKit's own JPEG/screen write options had no effect on macOS 27.)
        fileprivate var filter: QuartzFilter? {
            guard self != .none else { return nil }
            let (quality, resolution, maxSize): (Double, Double, Double) = self == .balanced ? (0.8, 200, 3000) : (0.6, 144, 2000)
            return QuartzFilter(properties: [
                "Domains": ["Applications": true],
                "FilterType": 1,
                "Name": "DEX \(rawValue)",
                "FilterData": ["ColorSettings": ["ImageSettings": [
                    "Compression Quality": quality,
                    "ImageCompression": "ImageJPEGCompress",
                    "ImageScaleSettings": [
                        "ImageResolution": resolution,
                        "ImageScaleInterpolate": true,
                        "ImageSizeMax": maxSize,
                        "ImageSizeMin": 0,
                    ],
                ]]],
            ])
        }
    }

    /// The document as PDF data, for saving or measuring in the background.
    public func snapshot(compression: Compression = .none) -> Data? {
        guard let filter = compression.filter else { return document.dataRepresentation() }
        // Quartz filters only apply when writing to a file.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dex-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        guard document.write(to: url, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// Writes data safely (temporary file, atomic move), never over `source`.
    public static func save(_ data: Data, to destination: URL, source: URL, overwrite: Bool) throws {
        try SafeOutput.write(to: destination, source: source, overwrite: overwrite) { temporary in
            try data.write(to: temporary)
            guard PDFDocument(url: temporary) != nil else {
                throw ConvertError.verificationFailed("the written PDF can't be opened")
            }
        }
    }

    public static func save(_ document: PDFDocument, to destination: URL, source: URL) throws {
        guard let data = document.dataRepresentation() else {
            throw ConvertError.encodeFailed(.jpeg, reason: "could not write the PDF")
        }
        try save(data, to: destination, source: source, overwrite: false)
    }
}
