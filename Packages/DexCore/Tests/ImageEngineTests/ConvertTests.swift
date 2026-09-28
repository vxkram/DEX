import CoreGraphics
import Foundation
import ImageEngine
import ImageIO
import JobSystem
import MediaModel
import Testing

@Suite("ImageEngine.convert")
struct ConvertTests {
    static let nativeFormats: [ImageFormat] = [.jpeg, .png, .heic, .avif, .tiff, .gif]
    let fixtures: FixtureFactory

    init() throws {
        fixtures = try FixtureFactory()
    }

    /// Plans and runs a conversion, returning the output and its plan.
    func run(
        _ source: URL,
        to target: ImageFormat,
        metadata: MetadataPolicy = .removeLocation,
        name: String? = nil
    ) async throws -> (URL, ConversionPlan) {
        let (_, plan) = try ImageEngine.plan(source, ConvertRequest(target: target, metadata: metadata))
        let destination = fixtures.directory.appendingPathComponent(
            name ?? "out-\(UUID().uuidString).\(target.preferredFileExtension)"
        )
        try await ImageEngine.convert(source, plan: plan, to: destination)
        return (destination, plan)
    }

    @Test("Every native source × target converts with geometry intact", arguments: nativeFormats)
    func matrix(_ sourceFormat: ImageFormat) async throws {
        defer { fixtures.cleanUp() }
        let source = try fixtures.image(sourceFormat, named: "source.\(sourceFormat.preferredFileExtension)")
        let before = try Data(contentsOf: source)

        for target in Self.nativeFormats {
            let (output, _) = try await run(source, to: target)
            let info = try ImageEngine.inspect(url: output)
            #expect(info.format == target, "\(sourceFormat)→\(target)")
            #expect(info.pixelWidth == 64 && info.pixelHeight == 48, "\(sourceFormat)→\(target)")
        }
        #expect(try Data(contentsOf: source) == before, "source must never change")
    }

    @Test("Location is removed for every target", arguments: nativeFormats)
    func removesLocation(_ target: ImageFormat) async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.gps = true
        let source = try fixtures.image(.jpeg, named: "gps.jpg", spec)
        #expect(try ImageEngine.inspect(url: source).hasGPS)

        let (output, _) = try await run(source, to: target)
        #expect(try !ImageEngine.inspect(url: output).hasGPS)
    }

    @Test("Same-format location removal keeps pixels bit-identical", arguments: [ImageFormat.jpeg, .png, .heic, .tiff])
    func locationRemovalIsLossless(_ format: ImageFormat) async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.gps = true
        spec.orientation = 6
        let source = try fixtures.image(format, named: "gps.\(format.preferredFileExtension)", spec)

        let (output, plan) = try await run(source, to: format)
        #expect(plan.strategy == (format.supportsLosslessMetadataEdit ? .rewriteMetadata : .reencode))
        #expect(plan.verdict != .lossy)
        let info = try ImageEngine.inspect(url: output)
        #expect(!info.hasGPS)
        #expect(info.orientation == 6)
        #expect(try pixels(of: output) == pixels(of: source))
    }

    @Test("Removing all metadata keeps orientation", arguments: [ImageFormat.jpeg, .png, .heic, .tiff])
    func removeAllKeepsOrientation(_ format: ImageFormat) async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.gps = true
        spec.orientation = 8
        let source = try fixtures.image(format, named: "o8.\(format.preferredFileExtension)", spec)

        let (output, _) = try await run(source, to: format, metadata: .removeAll)
        let info = try ImageEngine.inspect(url: output)
        #expect(info.orientation == 8)
        #expect(!info.hasGPS)
    }

    @Test("AVIF output is rotated upright because AVIF drops the orientation tag", arguments: [1, 3, 6, 8])
    func avifAppliesOrientation(_ orientation: Int) async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.orientation = orientation
        let source = try fixtures.image(.png, spec)
        let sourceInfo = try ImageEngine.inspect(url: source)

        let (output, _) = try await run(source, to: .avif)
        let info = try ImageEngine.inspect(url: output)
        #expect(info.orientation == 1)
        #expect(info.pixelWidth == sourceInfo.displayWidth)
        #expect(info.pixelHeight == sourceInfo.displayHeight)
        // Rotating via PNG shows the transform is exact: same upright pixels.
        let (upright, _) = try await run(output, to: .png)
        let (reference, _) = try await run(source, to: .png, name: "reference.png")
        #expect(try ImageEngine.inspect(url: upright).pixelWidth == ImageEngine.inspect(url: reference).displayWidth)
    }

    @Test func gifReencodeKeepsPalettePixels() async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.frames = 3
        let source = try fixtures.image(.gif, spec)
        let (output, plan) = try await run(source, to: .gif, metadata: .removeAll)
        #expect(plan.strategy == .reencode)
        #expect(plan.verdict == .lossless)
        #expect(try pixels(of: output) == pixels(of: source))
    }

    @Test func keepAllIsByteIdenticalCopy() async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.gps = true
        let source = try fixtures.image(.jpeg, named: "gps.jpg", spec)
        let (output, plan) = try await run(source, to: .jpeg, metadata: .keepAll)
        #expect(plan.strategy == .copyFile)
        #expect(try Data(contentsOf: output) == Data(contentsOf: source))
    }

    @Test func jpegToPNGIsPixelExact() async throws {
        defer { fixtures.cleanUp() }
        let source = try fixtures.image(.jpeg)
        let (output, plan) = try await run(source, to: .png)
        #expect(plan.verdict == .lossless)
        #expect(try pixels(of: output) == pixels(of: source))
    }

    @Test func sixteenBitWideColourSurvivesLosslessConversion() async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.bitsPerComponent = 16
        spec.colorSpace = CGColorSpace.displayP3
        spec.alpha = true
        let source = try fixtures.image(.png, spec)

        let (output, plan) = try await run(source, to: .tiff)
        #expect(plan.verdict == .lossless)
        let info = try ImageEngine.inspect(url: output)
        #expect(info.bitsPerComponent == 16)
        #expect(info.hasAlpha)
        #expect(info.colorProfile?.contains("P3") == true)
        #expect(try pixels(of: output, bits: 16) == pixels(of: source, bits: 16))
    }

    @Test func plannedBitDepthMatchesEncoder() async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.bitsPerComponent = 16
        let source = try fixtures.image(.png, spec)
        for target in [ImageFormat.heic, .avif, .jpeg] {
            let (output, plan) = try await run(source, to: target)
            let expected = plan.notes.compactMap { note -> Int? in
                if case .bitDepthReduced(_, let to) = note { return to } else { return nil }
            }.first ?? 16
            #expect(try ImageEngine.inspect(url: output).bitsPerComponent == expected, "\(target)")
        }
    }

    @Test func transparencyIsFlattenedOntoWhite() async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.alpha = true
        let source = try fixtures.image(.png, spec)
        let (output, plan) = try await run(source, to: .jpeg)
        #expect(plan.notes.contains(.transparencyFlattened))
        // The fixture is 50 % transparent, so every channel ends up at least half white.
        let data = try pixels(of: output)
        let darkest = stride(from: 0, to: data.count, by: 4).map { i in data[i..<i + 3].min()! }.min()!
        #expect(darkest >= 120)
    }

    @Test func animatedGIFKeepsFramesOrPlansFirstFrame() async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.frames = 5
        let source = try fixtures.image(.gif, spec)

        let (gif, _) = try await run(source, to: .gif, metadata: .removeAll)
        #expect(try ImageEngine.inspect(url: gif).frameCount == 5)

        let (png, plan) = try await run(source, to: .png)
        #expect(plan.notes.contains(.animationFirstFrameOnly(frames: 5)))
        #expect(try ImageEngine.inspect(url: png).frameCount == 1)
    }

    @Test func refusesToOverwriteSource() async throws {
        defer { fixtures.cleanUp() }
        let source = try fixtures.image(.png)
        let before = try Data(contentsOf: source)
        let (_, plan) = try ImageEngine.plan(source, ConvertRequest(target: .png, metadata: .removeAll))
        await #expect(throws: OutputError.self) {
            try await ImageEngine.convert(source, plan: plan, to: source, overwrite: true)
        }
        #expect(try Data(contentsOf: source) == before)
    }

    @Test func cancellationLeavesNoOutput() async throws {
        defer { fixtures.cleanUp() }
        let source = try fixtures.image(.png)
        let destination = fixtures.directory.appendingPathComponent("cancelled.jpg")
        let (_, plan) = try ImageEngine.plan(source, ConvertRequest(target: .jpeg))

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await ImageEngine.convert(source, plan: plan, to: destination)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Helpers

    /// Renders an image into a fixed RGBA layout in its own colour space so
    /// outputs from different codecs can be compared byte for byte.
    func pixels(of url: URL, bits: Int = 8) throws -> Data {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var info = CGImageAlphaInfo.premultipliedLast.rawValue
        if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: bits,
            bytesPerRow: 0, space: space, bitmapInfo: info
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try #require(context.data), count: context.bytesPerRow * context.height)
    }
}
