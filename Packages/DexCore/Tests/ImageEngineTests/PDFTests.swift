import CoreGraphics
import Foundation
@testable import ImageEngine
import ImageIO
import MediaModel
import Testing

@Suite("PDF")
struct PDFTests {
    let fixtures: FixtureFactory

    init() throws {
        fixtures = try FixtureFactory()
    }

    func solid(_ format: ImageFormat, _ name: String, _ w: Int, _ h: Int, _ rgb: (Double, Double, Double),
               orientation: Int = 1, gps: Bool = false, noise: Bool = false) async throws -> URL {
        var spec = FixtureFactory.Spec()
        spec.width = w
        spec.height = h
        spec.solid = noise ? nil : rgb
        spec.noise = noise
        spec.orientation = orientation
        spec.gps = gps
        return try await fixtures.image(format, named: "\(name).\(format.preferredFileExtension)", spec)
    }

    func makePDF(_ urls: [URL], _ size: PDFEngine.PageSize = .fitImage, margin: Double = 36) async throws -> URL {
        let output = fixtures.directory.appendingPathComponent("out-\(UUID().uuidString).pdf")
        try await PDFEngine.makePDF(from: urls.map { PDFEngine.PageImage(url: $0) }, pageSize: size,
                                    margin: margin, title: "Test", to: output)
        return output
    }

    func color(_ image: CGImage, x: Int, y: Int) throws -> (Int, Int, Int) {
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let p = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let i = (y * image.width + x) * 4
        return (Int(p[i]), Int(p[i + 1]), Int(p[i + 2]))
    }

    @Test func onePagePerImageAnyFormat() async throws {
        defer { fixtures.cleanUp() }
        let jpeg = try await solid(.jpeg, "a", 300, 200, (1, 0, 0))
        let png = try await solid(.png, "b", 200, 300, (0, 0, 1))
        let heic = try await solid(.heic, "c", 100, 100, (0, 1, 0))
        let pdf = try await makePDF([jpeg, png, heic])
        let info = try PDFEngine.info(url: pdf)
        #expect(info.pageCount == 3)
        #expect(info.pageSizes[0] == CGSize(width: 300, height: 200))
        #expect(info.pageSizes[1] == CGSize(width: 200, height: 300))
    }

    @Test func jpegIsEmbeddedWithoutReencoding() async throws {
        defer { fixtures.cleanUp() }
        let jpeg = try await solid(.jpeg, "photo", 400, 300, (0, 0, 0), noise: true)
        let pdf = try await makePDF([jpeg])
        let jpegData = try Data(contentsOf: jpeg)
        let pdfData = try Data(contentsOf: pdf)
        // The JPEG's entropy-coded scan must appear byte for byte in the PDF.
        let scan = try #require(jpegData.range(of: Data([0xFF, 0xDA])))
        let sample = jpegData[scan.lowerBound..<min(scan.lowerBound + 512, jpegData.count)]
        #expect(pdfData.range(of: sample) != nil, "JPEG data should be passed through untouched")
        #expect(pdfData.count < jpegData.count + 4096)
    }

    @Test func smallerPagesShrinkNonJPEGImages() async throws {
        defer { fixtures.cleanUp() }
        let png = try await solid(.png, "noisy", 600, 400, (0, 0, 0), noise: true)
        let lossless = try await makePDF([png])
        let smaller = fixtures.directory.appendingPathComponent("smaller.pdf")
        try await PDFEngine.makePDF(from: [PDFEngine.PageImage(url: png)], pageSize: .fitImage, margin: 0,
                                    title: "t", imageQuality: 0.9, to: smaller)
        let (big, small) = (try Data(contentsOf: lossless).count, try Data(contentsOf: smaller).count)
        #expect(small < big / 2, "JPEG pages should be much smaller (\(small) vs \(big))")
        #expect(try PDFEngine.info(url: smaller).pageSizes[0] == CGSize(width: 600, height: 400))
    }

    @Test func noLocationLeaksIntoThePDF() async throws {
        defer { fixtures.cleanUp() }
        let jpeg = try await solid(.jpeg, "gps", 200, 100, (1, 1, 1), gps: true)
        #expect(try Data(contentsOf: jpeg).range(of: Data("Exif".utf8)) != nil)
        let pdf = try await makePDF([jpeg])
        #expect(try Data(contentsOf: pdf).range(of: Data("Exif".utf8)) == nil)
    }

    @Test func rotatedPhotosAreUpright() async throws {
        defer { fixtures.cleanUp() }
        // Stored 200×100 with orientation 6: displayed 100×200.
        let jpeg = try await solid(.jpeg, "rotated", 200, 100, (1, 0, 0), orientation: 6)
        let pdf = try await makePDF([jpeg])
        #expect(try PDFEngine.info(url: pdf).pageSizes[0] == CGSize(width: 100, height: 200))
    }

    @Test func paperSizesFollowTheImage() async throws {
        defer { fixtures.cleanUp() }
        let wide = try await solid(.png, "wide", 800, 400, (1, 1, 0))
        let tall = try await solid(.png, "tall", 400, 800, (1, 1, 0))
        let pdf = try await makePDF([wide, tall], .a4)
        let sizes = try PDFEngine.info(url: pdf).pageSizes
        #expect(abs(sizes[0].width - 841.89) < 1 && abs(sizes[0].height - 595.28) < 1)  // landscape
        #expect(abs(sizes[1].width - 595.28) < 1 && abs(sizes[1].height - 841.89) < 1)  // portrait
    }

    @Test func pagesRenderAtTheRequestedDPI() async throws {
        defer { fixtures.cleanUp() }
        let png = try await solid(.png, "blue", 72, 36, (0, 0, 1))
        let pdf = try await makePDF([png])
        let page = try PDFEngine.renderPage(url: pdf, page: 1, dpi: 144)
        #expect(page.width == 144 && page.height == 72)
        let pixel = try color(page, x: 72, y: 36)
        #expect(pixel.2 > 230 && pixel.0 < 30)
    }

    @Test("Pages export to every format", arguments: [ImageFormat.png, .jpeg, .webp, .tiff])
    func exportPages(_ format: ImageFormat) async throws {
        defer { fixtures.cleanUp() }
        let a = try await solid(.png, "a", 100, 100, (1, 0, 0))
        let b = try await solid(.png, "b", 100, 50, (0, 1, 0))
        let pdf = try await makePDF([a, b])
        let folder = fixtures.directory.appendingPathComponent("pages", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = try await PDFEngine.exportPages(url: pdf, pages: [1, 2], dpi: 150, format: format,
                                                    lossyQuality: format.hasLossyMode ? 0.9 : nil, to: folder)
        #expect(files.count == 2)
        #expect(files[0].lastPathComponent.hasSuffix("-page-01.\(format.preferredFileExtension)"))
        let info = try ImageEngine.inspect(url: files[1])
        #expect(info.pixelWidth == 208 && info.pixelHeight == 104)  // 100×50 pt at 150 DPI
        // Exporting again never overwrites.
        let again = try await PDFEngine.exportPages(url: pdf, pages: [1], dpi: 72, format: format, lossyQuality: nil, to: folder)
        #expect(again[0] != files[0])
    }

    @Test func passwordProtectedPDFs() async throws {
        defer { fixtures.cleanUp() }
        let url = fixtures.directory.appendingPathComponent("locked.pdf")
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let info = [kCGPDFContextUserPassword: "secret", kCGPDFContextOwnerPassword: "owner"] as CFDictionary
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, info))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.closePDF()

        #expect(throws: PDFError.locked("locked.pdf")) { try PDFEngine.info(url: url) }
        #expect(throws: PDFError.wrongPassword) { try PDFEngine.info(url: url, password: "nope") }
        #expect(try PDFEngine.info(url: url, password: "secret").pageCount == 1)
    }

    @Test func detectsPDFs() async throws {
        defer { fixtures.cleanUp() }
        let png = try await solid(.png, "x", 10, 10, (1, 1, 1))
        #expect(!PDFEngine.isPDF(png))
        #expect(PDFEngine.isPDF(try await makePDF([png])))
    }
}
