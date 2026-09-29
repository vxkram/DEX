import CoreGraphics
import Foundation
import ImageIO
import JobSystem
import MediaModel

public enum PDFError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case locked(String)
    case wrongPassword
    case noPages
    case pageOutOfRange(Int)

    public var description: String {
        switch self {
        case .unreadable(let name): "“\(name)” isn't a PDF DEX can read."
        case .locked(let name): "“\(name)” is password-protected."
        case .wrongPassword: "That password didn't unlock the PDF."
        case .noPages: "There are no pages to export."
        case .pageOutOfRange(let page): "Page \(page) doesn't exist in this PDF."
        }
    }
}

/// Facts about a PDF, for the UI and planning.
public struct PDFInfo: Sendable, Equatable {
    public var fileName: String
    public var fileSize: Int64
    public var pageCount: Int
    /// Page sizes in points (1/72 inch), rotation applied.
    public var pageSizes: [CGSize]
    public var isEncrypted: Bool
}

/// Images → PDF and PDF → images.
public enum PDFEngine {
    public static func isPDF(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return url.pathExtension.lowercased() == "pdf"
        }
        return (CGImageSourceGetType(source) as String?) == "com.adobe.pdf"
    }

    // MARK: - Reading

    public static func info(url: URL, password: String? = nil) throws -> PDFInfo {
        let document = try open(url, password: password)
        let pages = (1...max(document.numberOfPages, 1)).compactMap { document.page(at: $0) }
        guard !pages.isEmpty, document.numberOfPages > 0 else { throw PDFError.noPages }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return PDFInfo(
            fileName: url.lastPathComponent, fileSize: size, pageCount: document.numberOfPages,
            pageSizes: pages.map(displaySize), isEncrypted: document.isEncrypted
        )
    }

    /// Renders one page (1-based) at `dpi`, on white.
    public static func renderPage(url: URL, page number: Int, dpi: Double, password: String? = nil) throws -> CGImage {
        let document = try open(url, password: password)
        guard let page = document.page(at: number) else { throw PDFError.pageOutOfRange(number) }
        return try render(page, dpi: dpi)
    }

    /// Renders pages and saves each as an image named
    /// "<pdf name>-page-01.<ext>" in `folder`, never overwriting anything.
    public static func exportPages(
        url: URL, pages: [Int], dpi: Double, format: ImageFormat, lossyQuality: Double?,
        to folder: URL, password: String? = nil, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [URL] {
        guard !pages.isEmpty else { throw PDFError.noPages }
        return try await MediaWork.run { token in
            let document = try open(url, password: password)
            let base = url.deletingPathExtension().lastPathComponent
            let digits = max(2, String(document.numberOfPages).count)
            var written: [URL] = []
            for (index, number) in pages.enumerated() {
                try token.check()
                guard let page = document.page(at: number) else { throw PDFError.pageOutOfRange(number) }
                let image = try render(page, dpi: dpi)
                let name = "\(base)-page-\(String(format: "%0\(digits)d", number))"
                let destination = SafeOutput.defaultDestination(
                    for: folder.appendingPathComponent(name).appendingPathExtension("pdf"),
                    pathExtension: format.preferredFileExtension
                )
                try SafeOutput.write(to: destination, source: url, cancellation: token) { temporary in
                    try encode(image, as: format, lossyQuality: lossyQuality, dpi: dpi, to: temporary, token: token)
                }
                written.append(destination)
                progress?(Double(index + 1) / Double(pages.count))
            }
            return written
        }
    }

    // MARK: - Writing

    public enum PageSize: String, Codable, Sendable, CaseIterable {
        /// Each page is exactly the image's size (at 72 pixels per inch).
        case fitImage
        case a4
        case letter

        var points: CGSize? {
            switch self {
            case .fitImage: nil
            case .a4: CGSize(width: 595.28, height: 841.89)
            case .letter: CGSize(width: 612, height: 792)
            }
        }
    }

    public struct PageImage: Sendable {
        public var url: URL
        /// Pixels to use instead of the file (e.g. after Crop edits).
        public var rendered: CGImageBox?

        public init(url: URL, rendered: CGImageBox? = nil) {
            self.url = url
            self.rendered = rendered
        }
    }

    /// Sendable wrapper; CGImage is immutable.
    public struct CGImageBox: @unchecked Sendable {
        public let image: CGImage
        public init(_ image: CGImage) { self.image = image }
    }

    /// One page per image. JPEGs are embedded as their original compressed
    /// data (no re-encode), with metadata stripped for privacy; other
    /// formats are stored losslessly. Rotation is applied to the page, not
    /// the pixels, so JPEGs stay untouched even when rotated.
    public static func makePDF(
        from images: [PageImage], pageSize: PageSize, margin: Double, title: String,
        to destination: URL, overwrite: Bool = false, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard let first = images.first else { throw PDFError.noPages }
        try await MediaWork.run { token in
            try SafeOutput.write(to: destination, source: first.url, overwrite: overwrite, cancellation: token) { temporary in
                let info = [kCGPDFContextTitle: title, kCGPDFContextCreator: "DEX"] as CFDictionary
                var box = CGRect(x: 0, y: 0, width: 612, height: 792)
                guard let context = CGContext(temporary as CFURL, mediaBox: &box, info) else {
                    throw ConvertError.encodeFailed(.jpeg, reason: "could not create the PDF")
                }
                for (index, item) in images.enumerated() {
                    try token.check()
                    let page = try pageContent(item)
                    let size = page.displaySize
                    var mediaBox = CGRect(origin: .zero, size: pageSize.points.map {
                        // Paper follows the image: landscape for wide images.
                        (size.width > size.height) == ($0.width > $0.height) ? $0 : CGSize(width: $0.height, height: $0.width)
                    } ?? size)
                    let inset = pageSize == .fitImage ? 0 : margin
                    let area = mediaBox.insetBy(dx: inset, dy: inset)
                    let scale = min(area.width / size.width, area.height / size.height, pageSize == .fitImage ? 1 : .infinity)
                    let drawn = CGSize(width: size.width * scale, height: size.height * scale)
                    let frame = CGRect(x: area.midX - drawn.width / 2, y: area.midY - drawn.height / 2,
                                       width: drawn.width, height: drawn.height)
                    let pageInfo = [kCGPDFContextMediaBox: NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size)] as CFDictionary
                    context.beginPDFPage(pageInfo)
                    draw(page, in: frame, context: context)
                    context.endPDFPage()
                    progress?(Double(index + 1) / Double(images.count))
                }
                context.closePDF()
            }
        }
    }

    // MARK: - Internals

    private static func open(_ url: URL, password: String?) throws -> CGPDFDocument {
        guard let document = CGPDFDocument(url as CFURL) else { throw PDFError.unreadable(url.lastPathComponent) }
        if !document.isUnlocked {
            guard let password else { throw PDFError.locked(url.lastPathComponent) }
            guard document.unlockWithPassword(password) else { throw PDFError.wrongPassword }
        }
        return document
    }

    private static func displaySize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        return page.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    private static func render(_ page: CGPDFPage, dpi: Double) throws -> CGImage {
        let scale = dpi / 72
        let size = displaySize(page)
        let width = max(Int((size.width * scale).rounded()), 1)
        let height = max(Int((size.height * scale).rounded()), 1)
        guard width * height <= Planner.maxMegapixels * 1_000_000,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else {
            throw ConvertError.encodeFailed(.png, reason: "page too large at \(Int(dpi)) DPI")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        // Maps the crop box (with its rotation) onto the page rectangle.
        let transform = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
        context.concatenate(transform)
        context.clip(to: page.getBoxRect(.cropBox))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw ConvertError.encodeFailed(.png, reason: "could not render the page") }
        return image
    }

    private static func encode(_ image: CGImage, as format: ImageFormat, lossyQuality: Double?, dpi: Double,
                               to url: URL, token: CancellationToken) throws {
        if format == .webp {
            try WebPWriter.write(image, lossyQuality: lossyQuality, to: url, token: token)
            return
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.typeIdentifier as CFString, 1, nil) else {
            throw ConvertError.encodeFailed(format)
        }
        var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if let lossyQuality, format.hasLossyMode { properties[kCGImageDestinationLossyCompressionQuality] = lossyQuality }
        if format == .tiff { properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConvertError.encodeFailed(format) }
    }

    /// What goes on a page: the pixels plus the orientation to draw with.
    private struct PageContent {
        var image: CGImage
        var orientation: Orientation
        var displaySize: CGSize {
            let size = orientation.apply(to: PixelSize(width: image.width, height: image.height))
            return CGSize(width: size.width, height: size.height)
        }
    }

    private static func pageContent(_ item: PageImage) throws -> PageContent {
        if let rendered = item.rendered { return PageContent(image: rendered.image, orientation: .identity) }
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil) else {
            throw ConvertError.unreadable(item.url.lastPathComponent)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = Orientation(exif: properties?[kCGImagePropertyOrientation] as? Int ?? 1)
        // JPEG: hand Core Graphics the compressed data so the PDF embeds it
        // as-is (DCTDecode), minus metadata so no location leaks into it.
        if (CGImageSourceGetType(source) as String?) == ImageFormat.jpeg.typeIdentifier,
           let data = try? Data(contentsOf: item.url, options: .alwaysMapped),
           let stripped = try? JPEGMarkers.strippingMetadata(data, orientation: 1),
           let provider = CGDataProvider(data: stripped as CFData),
           let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            return PageContent(image: jpeg, orientation: orientation)
        }
        return PageContent(image: try ImageEngine.decodedFrame(source, index: 0, name: item.url.lastPathComponent), orientation: orientation)
    }

    /// Draws with the orientation as a transform: rotation happens in the
    /// PDF, the embedded pixels are untouched.
    private static func draw(_ page: PageContent, in frame: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: frame.midX, y: frame.midY)
        let o = page.orientation
        // Display space is y-down; PDF is y-up, so clockwise turns are negative.
        context.rotate(by: -CGFloat(o.turns) * .pi / 2)
        let stored = o.swapsAxes ? CGSize(width: frame.height, height: frame.width) : frame.size
        if o.flipped {
            // Flip happens before the rotation in display space.
            context.scaleBy(x: -1, y: 1)
        }
        context.interpolationQuality = .high
        context.draw(page.image, in: CGRect(x: -stored.width / 2, y: -stored.height / 2, width: stored.width, height: stored.height))
        context.restoreGState()
    }
}
