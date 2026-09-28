import CoreGraphics
import Foundation
import ImageEngine
import ImageIO
import MediaModel
import Testing

@Suite("WebP output")
struct WebPTests {
    let fixtures: FixtureFactory

    init() throws {
        fixtures = try FixtureFactory()
    }

    func convert(_ source: URL, quality: QualityPreference = .maximum, metadata: MetadataPolicy = .removeLocation) async throws -> (URL, ConversionPlan) {
        let (_, plan) = try ImageEngine.plan(source, ConvertRequest(target: .webp, quality: quality, metadata: metadata))
        let output = fixtures.directory.appendingPathComponent("out-\(UUID().uuidString).webp")
        try await ImageEngine.convert(source, plan: plan, to: output)
        return (output, plan)
    }

    @Test func isWritable() {
        #expect(ImageEngine.writableFormats().contains(.webp))
    }

    @Test("Maximum quality is exact lossless WebP", arguments: [8, 16])
    func losslessIsPixelExact(_ bits: Int) async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.alpha = true
        spec.colorSpace = CGColorSpace.displayP3
        spec.bitsPerComponent = bits
        let source = try fixtures.image(.png, spec)

        let (output, plan) = try await convert(source)
        #expect(plan.lossyQuality == nil)
        let info = try ImageEngine.inspect(url: output)
        #expect(info.format == .webp)
        #expect(info.hasAlpha)
        #expect(info.colorProfile?.contains("P3") == true)
        if bits == 8 {
            #expect(plan.verdict == .lossless)
            #expect(try pixels(output) == pixels(source))
        } else {
            #expect(plan.notes.contains(.bitDepthReduced(from: 16, to: 8)))
        }
    }

    @Test func lowerQualityIsLossyAndSmaller() async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.width = 256
        spec.height = 192
        spec.noise = true
        let source = try fixtures.image(.png, spec)
        let (lossless, _) = try await convert(source)
        let (lossy, plan) = try await convert(source, quality: .custom(0.6))
        #expect(plan.verdict == .lossy)
        #expect(plan.notes.contains(.lossyEncode(.webp, quality: 0.6)))
        #expect(try size(lossy) < size(lossless))
    }

    @Test("Rotation is applied to the pixels", arguments: [3, 6, 8])
    func appliesOrientation(_ orientation: Int) async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.orientation = orientation
        let source = try fixtures.image(.png, spec)
        let sourceInfo = try ImageEngine.inspect(url: source)

        let (output, plan) = try await convert(source)
        #expect(plan.appliesOrientation)
        let info = try ImageEngine.inspect(url: output)
        #expect(info.orientation == 1)
        #expect(info.pixelWidth == sourceInfo.displayWidth)
        #expect(info.pixelHeight == sourceInfo.displayHeight)
        #expect(try pixels(output) == upright(source))
    }

    @Test func locationFollowsThePolicy() async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.gps = true
        let source = try fixtures.image(.jpeg, named: "gps.jpg", spec)

        let (kept, _) = try await convert(source, metadata: .keepAll)
        #expect(try ImageEngine.inspect(url: kept).hasGPS, "keep-all must really carry metadata")
        let (removed, _) = try await convert(source, metadata: .removeLocation)
        #expect(try !ImageEngine.inspect(url: removed).hasGPS)
        let (none, _) = try await convert(source, metadata: .removeAll)
        #expect(try !ImageEngine.inspect(url: none).hasGPS)
    }

    @Test func grayscaleIsConvertedAndDisclosed() async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.colorSpace = CGColorSpace.linearGray
        let source = try fixtures.image(.png, spec)
        let (output, plan) = try await convert(source)
        #expect(plan.notes.contains(.colourModelConverted(from: "Gray")))
        #expect(try ImageEngine.inspect(url: output).colorModel == "RGB")
    }

    @Test func cancellationLeavesNoOutput() async throws {
        defer { fixtures.cleanUp() }
        let source = try fixtures.image(.png)
        let (_, plan) = try ImageEngine.plan(source, ConvertRequest(target: .webp))
        let destination = fixtures.directory.appendingPathComponent("cancelled.webp")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await ImageEngine.convert(source, plan: plan, to: destination)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Helpers

    func size(_ url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }

    func pixels(_ url: URL) throws -> Data {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try render(try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    func upright(_ url: URL) throws -> Data {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try render(try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ] as CFDictionary)))
    }

    func render(_ image: CGImage) throws -> Data {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: space.model == .rgb ? space : CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try #require(context.data), count: image.width * image.height * 4)
    }
}
