import CoreGraphics
import Foundation
import ImageEngine
import MediaModel
import Testing

@Suite("ImageEngine.inspect")
struct InspectTests {
    let fixtures: FixtureFactory

    init() throws {
        fixtures = try FixtureFactory()
    }

    @Test("Reads every natively writable MVP format", arguments: [ImageFormat.jpeg, .png, .heic, .tiff, .gif, .avif])
    func readsFormat(_ format: ImageFormat) throws {
        defer { fixtures.cleanUp() }
        try #require(ImageEngine.canWrite(format), "\(format) is not writable on this macOS")
        let url = try fixtures.image(format)

        let info = try ImageEngine.inspect(url: url)

        #expect(info.format == format)
        #expect(info.pixelWidth == 64)
        #expect(info.pixelHeight == 48)
        #expect(info.frameCount == 1)
        #expect(info.fileSize > 0)
        #expect(info.fileName == url.lastPathComponent)
    }

    @Test func readsWebP() throws {
        defer { fixtures.cleanUp() }
        let info = try ImageEngine.inspect(url: try fixtures.webp())
        #expect(info.format == .webp)
        #expect(info.pixelWidth == 1)
        #expect(info.pixelHeight == 1)
    }

    @Test("EXIF orientation swaps display axes for 5–8", arguments: 1...8)
    func orientation(_ orientation: Int) throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.orientation = orientation
        let info = try ImageEngine.inspect(url: try fixtures.image(.jpeg, spec))

        #expect(info.orientation == orientation)
        #expect(info.pixelWidth == 64)
        #expect(info.pixelHeight == 48)
        let rotated = orientation >= 5
        #expect(info.displayWidth == (rotated ? 48 : 64))
        #expect(info.displayHeight == (rotated ? 64 : 48))
    }

    @Test func detectsGPS() throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.gps = true
        #expect(try ImageEngine.inspect(url: try fixtures.image(.jpeg, named: "gps.jpg", spec)).hasGPS)
        #expect(try !ImageEngine.inspect(url: try fixtures.image(.jpeg, named: "plain.jpg")).hasGPS)
    }

    @Test func detectsAlpha() throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.alpha = true
        #expect(try ImageEngine.inspect(url: try fixtures.image(.png, named: "alpha.png", spec)).hasAlpha)
        #expect(try !ImageEngine.inspect(url: try fixtures.image(.jpeg, named: "opaque.jpg")).hasAlpha)
    }

    @Test func reportsSixteenBitDepthAndWideColour() throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.bitsPerComponent = 16
        spec.colorSpace = CGColorSpace.displayP3
        let info = try ImageEngine.inspect(url: try fixtures.image(.png, spec))

        #expect(info.bitsPerComponent == 16)
        #expect(info.colorModel == "RGB")
        #expect(info.colorProfile?.contains("P3") == true)
    }

    @Test func countsAnimatedGIFFrames() throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.frames = 5
        let info = try ImageEngine.inspect(url: try fixtures.image(.gif, spec))
        #expect(info.frameCount == 5)
        #expect(info.isAnimated)
    }

    @Test func plainImageHasNoGainMap() throws {
        defer { fixtures.cleanUp() }
        #expect(try !ImageEngine.inspect(url: try fixtures.image(.heic)).hasHDRGainMap)
    }

    // MARK: - Hostile and broken input

    @Test func rejectsMissingFile() {
        defer { fixtures.cleanUp() }
        let url = URL(fileURLWithPath: "/nonexistent/dex/missing.jpg")
        #expect(throws: InspectError.fileNotFound("missing.jpg")) { try ImageEngine.inspect(url: url) }
    }

    @Test func rejectsDirectory() {
        defer { fixtures.cleanUp() }
        #expect(throws: InspectError.notAFile(fixtures.directory.lastPathComponent)) {
            try ImageEngine.inspect(url: fixtures.directory)
        }
    }

    @Test func rejectsEmptyFile() throws {
        defer { fixtures.cleanUp() }
        let url = try fixtures.file(named: "empty.jpg", contents: Data())
        #expect(throws: InspectError.emptyFile("empty.jpg")) { try ImageEngine.inspect(url: url) }
    }

    @Test func rejectsTextWithImageExtension() throws {
        defer { fixtures.cleanUp() }
        let url = try fixtures.file(named: "notes.jpg", contents: Data("definitely not a jpeg".utf8))
        #expect(throws: InspectError.self) { try ImageEngine.inspect(url: url) }
    }

    @Test("Truncated files fail cleanly instead of crashing", arguments: [ImageFormat.jpeg, .png, .heic])
    func rejectsTruncated(_ format: ImageFormat) throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.width = 256
        spec.height = 256
        let original = try Data(contentsOf: try fixtures.image(format, spec))
        let url = try fixtures.file(named: "truncated.\(format.preferredFileExtension)", contents: original.prefix(64))
        #expect(throws: InspectError.self) { try ImageEngine.inspect(url: url) }
    }

    @Test func handlesUnicodeAndSpacesInPath() throws {
        defer { fixtures.cleanUp() }
        let name = "Photo 📷 déjà vu.png"
        let info = try ImageEngine.inspect(url: try fixtures.image(.png, named: name))
        #expect(info.fileName == name)
    }

    @Test func inspectDoesNotModifySource() throws {
        defer { fixtures.cleanUp() }
        let url = try fixtures.image(.jpeg)
        let before = try Data(contentsOf: url)
        _ = try ImageEngine.inspect(url: url)
        #expect(try Data(contentsOf: url) == before)
    }
}
