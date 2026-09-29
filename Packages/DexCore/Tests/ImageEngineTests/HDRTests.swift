import CoreGraphics
import Foundation
@testable import ImageEngine
import ImageIO
import MediaModel
import Testing

@Suite("HDR gain maps")
struct HDRTests {
    let fixtures: FixtureFactory

    init() throws {
        fixtures = try FixtureFactory()
    }

    // MARK: - Synthetic ISO gain map (runs everywhere, including CI)

    @Test("Gain map survives conversion to formats that can store one", arguments: [ImageFormat.jpeg, .heic, .avif])
    func keepsGainMap(_ target: ImageFormat) async throws {
        defer { fixtures.cleanUp() }
        let source = try await fixtures.hdrImage(.heic)
        let sourceHeadroom = try headroom(of: source)
        #expect(sourceHeadroom > 1.5, "fixture must really be HDR")

        let (_, plan) = try ImageEngine.plan(source, ConvertRequest(target: target))
        #expect(plan.preservesHDR)
        #expect(!plan.notes.contains(.hdrDropped(to: target)))

        let output = fixtures.directory.appendingPathComponent("out.\(target.preferredFileExtension)")
        try await ImageEngine.convert(source, plan: plan, to: output)
        #expect(try ImageEngine.inspect(url: output).hasHDRGainMap)
        #expect(abs(try headroom(of: output) - sourceHeadroom) < 0.1)
    }

    @Test("HDR drop is disclosed for formats without gain maps", arguments: [ImageFormat.png, .tiff])
    func disclosesDrop(_ target: ImageFormat) async throws {
        defer { fixtures.cleanUp() }
        let source = try await fixtures.hdrImage(.heic)
        let (_, plan) = try ImageEngine.plan(source, ConvertRequest(target: target))
        #expect(plan.verdict == .lossy)
        #expect(plan.notes.contains(.hdrDropped(to: target)))
        #expect(!plan.preservesHDR)
    }

    // MARK: - Gain map rotation

    @Test("Bitmap orientation matches ImageIO's own transform", arguments: 1...8)
    func orientationMatchesImageIO(_ orientation: Int) async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.orientation = orientation
        spec.width = 7
        spec.height = 5
        let url = try await fixtures.image(.png, spec)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))

        let stored = try rgba(try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        let upright = try rgba(try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 7,
        ] as CFDictionary)))

        #expect(stored.oriented(orientation) == upright)
    }

    // MARK: - Real iPhone photo (opt-in, local only)

    /// Set DEX_HDR_SAMPLE to an iPhone HEIC with an HDR gain map, e.g.
    /// `DEX_HDR_SAMPLE=~/Downloads/IMG_1234.HEIC make test`.
    static let sample = ProcessInfo.processInfo.environment["DEX_HDR_SAMPLE"]
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

    @Test(
        "Real iPhone HDR keeps its headroom through every path",
        .enabled(if: sample != nil, "set DEX_HDR_SAMPLE to run"),
        arguments: [
            (ImageFormat.jpeg, MetadataPolicy.removeLocation),
            (.jpeg, .removeAll),
            (.heic, .removeLocation),
            (.heic, .removeAll),
            (.avif, .removeLocation),
            (.avif, .removeAll),
        ]
    )
    func realSample(_ target: ImageFormat, _ metadata: MetadataPolicy) async throws {
        defer { fixtures.cleanUp() }
        let source = try #require(Self.sample)
        let sourceHeadroom = try headroom(of: source)
        let (_, plan) = try ImageEngine.plan(source, ConvertRequest(target: target, metadata: metadata))
        let output = fixtures.directory.appendingPathComponent("real.\(target.preferredFileExtension)")
        try await ImageEngine.convert(source, plan: plan, to: output)

        #expect(abs(try headroom(of: output) - sourceHeadroom) < 0.05, "\(target) \(metadata)")
        #expect(try !ImageEngine.inspect(url: output).hasGPS)
        // The gain map must still line up with the photo, including after
        // AVIF's rotation, so the HDR renderings must match closely.
        // Calibrated against the same photo with HDR dropped (~0.10 for the
        // reference iPhone photo): kept HDR must be at least 10× closer.
        let sdrOnly = fixtures.directory.appendingPathComponent("sdr-only.png")
        let sdrPlan = try Planner.plan(try ImageEngine.inspect(url: source), ConvertRequest(target: .png), writable: [.png])
        try await ImageEngine.convert(source, plan: sdrPlan, to: sdrOnly)
        let difference = try hdrDifference(source, output)
        #expect(difference < 0.02, "\(target) \(metadata)")
        #expect(difference * 10 < (try hdrDifference(source, sdrOnly)), "\(target) \(metadata)")
    }

    // MARK: - Helpers

    func headroom(of url: URL) throws -> Double {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary
        ))
        return Double(image.contentHeadroom)
    }

    /// Mean absolute difference of the upright HDR renderings, in linear light.
    func hdrDifference(_ a: URL, _ b: URL) throws -> Double {
        let (pa, pb) = (try hdrPixels(a), try hdrPixels(b))
        #expect(pa.count == pb.count)
        var total = 0.0
        var count = 0
        for (x, y) in zip(pa, pb) where x.isFinite && y.isFinite {
            total += Double(abs(x - y))
            count += 1
        }
        #expect(count > pa.count * 9 / 10, "most pixels must be finite")
        return total / Double(max(count, 1))
    }

    func hdrPixels(_ url: URL, width: Int = 96) throws -> [Float] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
        ] as CFDictionary))
        let height = width * image.height / image.width
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 32, bytesPerRow: width * 16, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.interpolationQuality = .medium
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pointer = try #require(context.data).assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: pointer, count: width * height * 4))
    }

    func rgba(_ image: CGImage) throws -> RawBitmap {
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = Data(bytes: try #require(context.data), count: image.width * image.height * 4)
        return RawBitmap(data: data, width: image.width, height: image.height, bytesPerRow: image.width * 4, bytesPerPixel: 4)
    }
}
