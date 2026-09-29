import AppKit
import Foundation
@testable import ImageEngine
import JobSystem
import MediaModel
import PDFKit
import Testing

@Suite("PDF editor")
struct PDFEditorTests {
    let fixtures: FixtureFactory

    init() throws {
        fixtures = try FixtureFactory()
    }

    /// A PDF whose pages say "Page 1", "Page 2", … as real text.
    func textPDF(_ count: Int, name: String = "doc.pdf", withPhoto: Bool = false) throws -> URL {
        let url = fixtures.directory.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for page in 1...count {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("Page \(page)" as NSString).draw(at: NSPoint(x: 72, y: 760), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
            NSGraphicsContext.restoreGraphicsState()
            if withPhoto {
                // A large noisy image, so compression has something to do.
                let side = 900
                let bitmap = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                var state: UInt32 = 7
                // Per-pixel noise, like photo grain: lossless storage can't
                // squeeze it, JPEG can.
                let pixels = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
                for i in 0..<(bitmap.bytesPerRow * side) {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    pixels[i] = UInt8(truncatingIfNeeded: state >> 24)
                }
                context.draw(try #require(bitmap.makeImage()), in: CGRect(x: 72, y: 100, width: 450, height: 450))
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    func labels(_ editor: PDFEditor) -> [String] {
        (0..<editor.pageCount).map { editor.page($0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    }

    func labels(_ document: PDFDocument) -> [String] {
        (0..<document.pageCount).map { document.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    }

    @Test func rearrangesPages() throws {
        defer { fixtures.cleanUp() }
        let editor = try PDFEditor(url: try textPDF(4))
        editor.movePage(from: 3, to: 0)
        #expect(labels(editor) == ["Page 4", "Page 1", "Page 2", "Page 3"])
        editor.movePages([1, 2], to: 2)
        #expect(labels(editor) == ["Page 4", "Page 3", "Page 1", "Page 2"])
    }

    @Test func rotatesWithoutTouchingContent() throws {
        defer { fixtures.cleanUp() }
        let editor = try PDFEditor(url: try textPDF(2))
        editor.rotate([0], quarterTurns: 1)
        editor.rotate([1], quarterTurns: -1)
        #expect(editor.page(0)?.rotation == 90)
        #expect(editor.page(1)?.rotation == 270)
        #expect(labels(editor) == ["Page 1", "Page 2"], "text must survive rotation")
    }

    @Test func deletesButNeverTheLastPage() throws {
        defer { fixtures.cleanUp() }
        let editor = try PDFEditor(url: try textPDF(3))
        editor.delete([0, 2])
        #expect(labels(editor) == ["Page 2"])
        editor.delete([0])
        #expect(editor.pageCount == 1)
    }

    @Test func extractsPagesIntoANewPDF() throws {
        defer { fixtures.cleanUp() }
        let editor = try PDFEditor(url: try textPDF(5))
        let extracted = editor.extract([4, 1])
        #expect(labels(extracted) == ["Page 2", "Page 5"])
        #expect(editor.pageCount == 5, "extracting must not change the original")
    }

    @Test func mergesAnotherPDF() throws {
        defer { fixtures.cleanUp() }
        let editor = try PDFEditor(url: try textPDF(2))
        let added = try editor.insertPDF(try textPDF(3, name: "other.pdf"), at: 1)
        #expect(added == 3)
        #expect(labels(editor) == ["Page 1", "Page 1", "Page 2", "Page 3", "Page 2"])
    }

    @Test("Images of any format become pages", arguments: [ImageFormat.jpeg, .png, .heic])
    func addsImagePages(_ format: ImageFormat) async throws {
        defer { fixtures.cleanUp() }
        let editor = try PDFEditor(url: try textPDF(1))
        var spec = FixtureFactory.Spec()
        spec.width = 300
        spec.height = 200
        spec.orientation = 6
        try editor.insertImage(try await fixtures.image(format, spec))
        #expect(editor.pageCount == 2)
        let size = try #require(editor.page(1)).bounds(for: .mediaBox).size
        #expect(size == CGSize(width: 200, height: 300), "rotated photo must be upright")
    }

    @Test func splitsEveryNPagesOrAtChosenPages() throws {
        defer { fixtures.cleanUp() }
        let editor = try PDFEditor(url: try textPDF(5))
        #expect(editor.split(every: 2).map(\.pageCount) == [2, 2, 1])
        let parts = editor.split(before: [2, 4])
        #expect(parts.map(\.pageCount) == [2, 2, 1])
        #expect(labels(parts[1]) == ["Page 3", "Page 4"])
    }

    @Test("Text lands on the page, even rotated ones", arguments: [0, 90])
    func addsText(_ rotation: Int) throws {
        defer { fixtures.cleanUp() }
        let source = try textPDF(1)
        let editor = try PDFEditor(url: source)
        editor.rotate([0], quarterTurns: rotation / 90)
        editor.addText("Approved", page: 0, position: .bottomRight, fontSize: 18, color: .red)
        let page = try #require(editor.page(0))
        let annotation = try #require(page.annotations.first)
        #expect(annotation.contents == "Approved")
        #expect(page.bounds(for: .cropBox).contains(annotation.bounds))

        // It survives saving and reopening.
        let output = fixtures.directory.appendingPathComponent("with-text.pdf")
        let data = try #require(editor.snapshot())
        try PDFEditor.save(data, to: output, source: source, overwrite: false)
        #expect(PDFDocument(url: output)?.page(at: 0)?.annotations.first?.contents == "Approved")
    }

    @Test func compressionShrinksImages() throws {
        defer { fixtures.cleanUp() }
        let editor = try PDFEditor(url: try textPDF(2, withPhoto: true))
        let original = try #require(editor.snapshot(compression: .none)).count
        let balanced = try #require(editor.snapshot(compression: .balanced)).count
        let smallest = try #require(editor.snapshot(compression: .smallest)).count
        #expect(balanced < original, "\(balanced) should be less than \(original)")
        #expect(smallest <= balanced)
        let compressed = try #require(editor.snapshot(compression: .smallest))
        let reopened = try #require(PDFDocument(data: compressed))
        #expect(labels(reopened) == ["Page 1", "Page 2"], "text must stay text")
    }

    @Test func savingNeverOverwritesTheOriginal() throws {
        defer { fixtures.cleanUp() }
        let source = try textPDF(1)
        let editor = try PDFEditor(url: source)
        let data = try #require(editor.snapshot())
        #expect(throws: OutputError.self) {
            try PDFEditor.save(data, to: source, source: source, overwrite: true)
        }
    }
}
