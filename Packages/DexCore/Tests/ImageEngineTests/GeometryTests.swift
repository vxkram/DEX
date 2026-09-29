import CoreGraphics
import Foundation
@testable import ImageEngine
import ImageIO
import MediaModel
import Testing

@Suite("Geometry")
struct GeometryTests {
    let fixtures: FixtureFactory

    init() throws {
        fixtures = try FixtureFactory()
    }

    func run(_ source: URL, _ target: ImageFormat, _ geometry: Geometry, metadata: MetadataPolicy = .removeLocation) async throws -> (URL, ConversionPlan) {
        let (_, plan) = try ImageEngine.plan(source, ConvertRequest(target: target, metadata: metadata, geometry: geometry))
        let output = fixtures.directory.appendingPathComponent("out-\(UUID().uuidString).\(target.preferredFileExtension)")
        try await ImageEngine.convert(source, plan: plan, to: output)
        return (output, plan)
    }

    // MARK: Orientation algebra matches real pixel moves

    @Test("Composition matches applying two orientations to pixels", arguments: 1...8)
    func compositionMatchesPixels(_ first: Int) {
        let bitmap = RawBitmap(data: Data((0..<6).map(UInt8.init)), width: 3, height: 2, bytesPerRow: 3, bytesPerPixel: 1)
        for second in 1...8 {
            let composed = Orientation(exif: first).followed(by: Orientation(exif: second)).exif
            #expect(bitmap.oriented(first).oriented(second) == bitmap.oriented(composed), "\(first) then \(second)")
        }
    }

    @Test("Rect mapping matches cropping before or after orienting", arguments: 1...8)
    func rectMappingMatchesPixels(_ exif: Int) {
        let bitmap = RawBitmap(data: Data((0..<35).map(UInt8.init)), width: 7, height: 5, bytesPerRow: 7, bytesPerPixel: 1)
        let rect = PixelRect(x: 1, y: 2, width: 4, height: 2)
        let mapped = Orientation(exif: exif).apply(to: rect, in: PixelSize(width: 7, height: 5))
        #expect(bitmap.cropped(to: rect).oriented(exif) == bitmap.oriented(exif).cropped(to: mapped))
    }

    // MARK: JPEG lossless crop

    @Test func jpegBlockSizeIsReported() async throws {
        defer { fixtures.cleanUp() }
        let info = try ImageEngine.inspect(url: try await fixtures.image(.jpeg))
        let block = try #require(info.jpegBlockSize)
        #expect([8, 16].contains(block.width) && [8, 16].contains(block.height))
    }

    @Test func jpegCropKeepsTheCompressedPixels() async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.width = 256
        spec.height = 192
        spec.noise = true
        spec.gps = true
        let source = try await fixtures.image(.jpeg, named: "photo.jpg", spec)
        let crop = PixelRect(x: 32, y: 48, width: 160, height: 96)

        let (output, plan) = try await run(source, .jpeg, Geometry(crop: crop))
        #expect(plan.strategy == .losslessJPEGCrop)
        let info = try ImageEngine.inspect(url: output)
        #expect(info.pixelWidth == 160 && info.pixelHeight == 96)
        #expect(!info.hasGPS)
        // Same DCT blocks: away from the new edges (chroma upsampling reads
        // one neighbour) the decoded pixels are identical.
        let original = try rgba(source).cropped(to: crop)
        let result = try rgba(output)
        #expect(maxDifference(original, result, border: 2) == 0)
    }

    @Test func rotatedJPEGCropShowsTheSameRegion() async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.width = 256
        spec.height = 128
        spec.noise = true
        spec.orientation = 6
        let source = try await fixtures.image(.jpeg, named: "rotated.jpg", spec)
        // Displayed 128×256; crop the lower-left block region.
        let crop = PixelRect(x: 0, y: 128, width: 64, height: 128)
        let (output, plan) = try await run(source, .jpeg, Geometry(crop: crop))
        #expect(plan.strategy == .losslessJPEGCrop)
        let info = try ImageEngine.inspect(url: output)
        #expect(info.orientation == 6)
        #expect(info.displayWidth == 64 && info.displayHeight == 128)
        let expected = try upright(source).cropped(to: plan.displayCrop!)
        #expect(maxDifference(expected, try upright(output), border: 2) == 0)
    }

    // MARK: Exact pixel ops

    @Test("Crop and rotate are exact for lossless formats", arguments: [ImageFormat.png, .tiff, .webp])
    func exactForLosslessFormats(_ target: ImageFormat) async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.alpha = true
        spec.noise = true
        let source = try await fixtures.image(.png, spec)
        var geometry = Geometry()
        geometry.rotateClockwise()
        geometry.crop = PixelRect(x: 5, y: 9, width: 30, height: 40)

        let (output, plan) = try await run(source, target, geometry)
        #expect(plan.verdict == .lossless)
        let info = try ImageEngine.inspect(url: output)
        #expect(info.displayWidth == 30 && info.displayHeight == 40)
        let expected = try rgba(source).oriented(6).cropped(to: geometry.crop!)
        #expect(maxDifference(expected, try upright(output), border: 0) == 0)
    }

    @Test("Rotation works for every format", arguments: [ImageFormat.jpeg, .png, .heic, .avif, .webp, .tiff, .gif])
    func rotatesEveryFormat(_ format: ImageFormat) async throws {
        defer { fixtures.cleanUp() }
        let source = format == .webp ? try await fixtures.image(.png, named: "src.png") : try await fixtures.image(format)
        var geometry = Geometry()
        geometry.rotateCounterclockwise()
        let (output, _) = try await run(source, format, geometry)
        let info = try ImageEngine.inspect(url: output)
        #expect(info.displayWidth == 48 && info.displayHeight == 64, "\(format)")
    }

    @Test func resizeProducesTheRequestedSizeAndLooksRight() async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.width = 400
        spec.height = 300
        spec.bitsPerComponent = 16
        spec.colorSpace = CGColorSpace.displayP3
        let source = try await fixtures.image(.png, spec)
        let (output, plan) = try await run(source, .png, Geometry(resize: PixelSize(width: 200, height: 150)))
        #expect(plan.verdict == .lossy)
        let info = try ImageEngine.inspect(url: output)
        #expect(info.pixelWidth == 200 && info.pixelHeight == 150)
        #expect(info.bitsPerComponent == 16)
        #expect(info.colorProfile?.contains("P3") == true)
    }

    @Test func animatedGIFCropKeepsEveryFrame() async throws {
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.frames = 4
        let source = try await fixtures.image(.gif, spec)
        let (output, _) = try await run(source, .gif, Geometry(crop: PixelRect(x: 4, y: 4, width: 20, height: 20)))
        let info = try ImageEngine.inspect(url: output)
        #expect(info.frameCount == 4)
        #expect(info.pixelWidth == 20 && info.pixelHeight == 20)
    }

    @Test func hdrFollowsCropAndResize() async throws {
        defer { fixtures.cleanUp() }
        let source = try await fixtures.hdrImage(.heic, width: 128, height: 96)
        let geometry = Geometry(crop: PixelRect(x: 64, y: 0, width: 64, height: 96), resize: PixelSize(width: 32, height: 48))
        let (output, plan) = try await run(source, .heic, geometry)
        #expect(plan.preservesHDR)
        #expect(try ImageEngine.inspect(url: output).hasHDRGainMap)
    }

    // MARK: - Helpers

    func rgba(_ url: URL) throws -> RawBitmap {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try render(try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    func upright(_ url: URL) throws -> RawBitmap {
        let stored = try rgba(url)
        return stored.oriented(try ImageEngine.inspect(url: url).orientation)
    }

    func render(_ image: CGImage) throws -> RawBitmap {
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = Data(bytes: try #require(context.data), count: image.width * image.height * 4)
        return RawBitmap(data: data, width: image.width, height: image.height, bytesPerRow: image.width * 4, bytesPerPixel: 4)
    }

    /// Largest channel difference, ignoring `border` pixels at each edge.
    func maxDifference(_ a: RawBitmap, _ b: RawBitmap, border: Int) -> Int {
        guard a.width == b.width, a.height == b.height else { return .max }
        var worst = 0
        for y in border..<(a.height - border) {
            for x in border..<(a.width - border) {
                for c in 0..<4 {
                    let i = y * a.bytesPerRow + x * 4 + c
                    worst = max(worst, abs(Int(a.data[i]) - Int(b.data[i])))
                }
            }
        }
        return worst
    }
}
