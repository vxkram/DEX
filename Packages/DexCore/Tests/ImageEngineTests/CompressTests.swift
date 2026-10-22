import CoreGraphics
import Foundation
@testable import ImageEngine
import ImageIO
import MediaModel
import Testing

@Suite("Compression")
struct CompressTests {
    let fixtures: FixtureFactory

    init() throws {
        fixtures = try FixtureFactory()
    }

    func size(_ url: URL) throws -> Int { try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }

    func run(_ source: URL, _ request: ConvertRequest) async throws -> (URL, ConversionPlan) {
        let (_, plan) = try ImageEngine.plan(source, request)
        let output = fixtures.directory.appendingPathComponent("out-\(UUID().uuidString).\(request.target.preferredFileExtension)")
        try await ImageEngine.convert(source, plan: plan, to: output)
        return (output, plan)
    }

    func noisy(_ format: ImageFormat) async throws -> URL {
        var spec = FixtureFactory.Spec()
        spec.width = 256
        spec.height = 192
        spec.noise = true
        return try await fixtures.image(format, named: "noisy.\(format.preferredFileExtension)", spec)
    }

    @Test func jpegRepackKeepsEveryPixel() async throws {
        defer { fixtures.cleanUp() }
        let source = try await noisy(.jpeg)
        let (output, plan) = try await run(source, ConvertRequest(target: .jpeg, optimize: true))
        #expect(plan.strategy == .losslessJPEGTransform)
        #expect(try pixels(output) == pixels(source))
        #expect(try size(output) <= size(source))
    }

    @Test("Removing metadata never grows a JPEG", arguments: [1, 6])
    func removingMetadataShrinks(_ orientation: Int) async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.width = 96
        spec.height = 64
        spec.gps = true
        spec.orientation = orientation
        let source = try await fixtures.image(.jpeg, named: "small.jpg", spec)

        let (output, plan) = try await run(source, ConvertRequest(target: .jpeg, metadata: .removeAll))
        #expect(plan.strategy == .losslessJPEGTransform)
        #expect(plan.verdict == .noReencode)
        #expect(try size(output) < size(source))
        let info = try ImageEngine.inspect(url: output)
        #expect(!info.hasGPS)
        #expect(info.orientation == orientation)
        #expect(try pixels(output) == pixels(source))
    }

    @Test func strippingKeepsTheColourProfile() async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.colorSpace = CGColorSpace.displayP3
        spec.gps = true
        let source = try await fixtures.image(.jpeg, named: "p3.jpg", spec)
        let (output, _) = try await run(source, ConvertRequest(target: .jpeg, metadata: .removeAll))
        #expect(try ImageEngine.inspect(url: output).colorProfile?.contains("P3") == true)
        #expect(try pixels(output) == pixels(source))
    }

    @Test func tiffIsLZWCompressedLosslessly() async throws {
        defer { fixtures.cleanUp() }
        let source = try await noisy(.tiff)
        let (output, plan) = try await run(source, ConvertRequest(target: .tiff, optimize: true))
        #expect(plan.verdict == .lossless)
        #expect(try pixels(output) == pixels(source))
        #expect(try size(output) < size(source))
    }

    @Test func lowerJPEGQualityShrinksTheFile() async throws {
        defer { fixtures.cleanUp() }
        let source = try await noisy(.jpeg)
        let (output, _) = try await run(source, ConvertRequest(target: .jpeg, quality: .custom(0.4)))
        #expect(try size(output) < size(source))
    }

    @Test("The estimate is the real size", arguments: [ImageFormat.jpeg, .png, .webp, .tiff])
    func estimateMatchesExport(_ target: ImageFormat) async throws {
        defer { fixtures.cleanUp() }
        let source = try await noisy(.png)
        let (_, plan) = try ImageEngine.plan(source, ConvertRequest(target: target))
        let estimate = try await ImageEngine.estimatedSize(source, plan: plan)
        let (output, _) = try await run(source, ConvertRequest(target: target))
        #expect(estimate == Int64(try size(output)), "\(target)")
    }

    func pixels(_ url: URL) throws -> Data {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try #require(context.data), count: image.width * image.height * 4)
    }
}
