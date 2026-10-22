import CoreGraphics
import Foundation
@testable import ImageEngine
import ImageIO
import MediaModel
import Testing

@Suite("Animation timeline")
struct AnimationTests {
    let fixtures: FixtureFactory

    init() throws {
        fixtures = try FixtureFactory()
    }

    func gif(frames: Int = 6) async throws -> URL {
        var spec = FixtureFactory.Spec()
        spec.frames = frames
        spec.delays = (0..<frames).map { 0.1 + Double($0) * 0.05 }
        return try await fixtures.image(.gif, spec)
    }

    func run(_ source: URL, _ request: ConvertRequest) async throws -> (URL, ConversionPlan) {
        let (_, plan) = try ImageEngine.plan(source, request)
        let output = fixtures.directory.appendingPathComponent("out-\(UUID().uuidString).\(request.target.preferredFileExtension)")
        try await ImageEngine.convert(source, plan: plan, to: output)
        return (output, plan)
    }

    @Test func framesAndDelaysAreRead() async throws {
        defer { fixtures.cleanUp() }
        let animation = try await ImageEngine.animationFrames(url: try await gif())
        #expect(animation.frames.count == 6)
        #expect(animation.delays.map { ($0 * 100).rounded() } == [10, 15, 20, 25, 30, 35])
        #expect(abs(animation.duration(of: 1...2) - 0.35) < 0.001)
    }

    @Test func trimmedGIFKeepsItsFramesAndTiming() async throws {
        defer { fixtures.cleanUp() }
        let source = try await gif()
        var request = ConvertRequest(target: .gif)
        request.geometry.frameRange = 2...4
        let (output, _) = try await run(source, request)
        let out = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetCount(out) == 3)
        let delays = (0..<3).map { (ImageEngine.frameDelay(out, $0) * 100).rounded() }
        #expect(delays == [20, 25, 30])
        // The same pixels as the source's frames 2…4.
        let original = try #require(CGImageSourceCreateWithURL(source as CFURL, nil))
        for i in 0..<3 {
            #expect(try pixels(ImageEngine.decodedFrame(out, index: i, name: "out")) ==
                    pixels(ImageEngine.decodedFrame(original, index: i + 2, name: "in")), "frame \(i)")
        }
    }

    @Test func stillFrameIsTheOneChosen() async throws {
        defer { fixtures.cleanUp() }
        let source = try await gif()
        var request = ConvertRequest(target: .png)
        request.geometry.stillFrame = 4
        let (output, _) = try await run(source, request)
        let original = try #require(CGImageSourceCreateWithURL(source as CFURL, nil))
        let still = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let expected = try pixels(ImageEngine.decodedFrame(original, index: 4, name: "in"))
        #expect(try pixels(ImageEngine.decodedFrame(still, index: 0, name: "out")) == expected)
        #expect(try pixels(ImageEngine.decodedFrame(original, index: 0, name: "in")) != expected, "frames differ")
    }

    @Test func croppedTrimAppliesToEveryFrame() async throws {
        defer { fixtures.cleanUp() }
        var request = ConvertRequest(target: .gif, geometry: Geometry(crop: PixelRect(x: 4, y: 4, width: 20, height: 20)))
        request.geometry.frameRange = 1...3
        let (output, _) = try await run(try await gif(), request)
        let info = try ImageEngine.inspect(url: output)
        #expect(info.frameCount == 3 && info.pixelWidth == 20 && info.pixelHeight == 20)
    }

    /// sRGB 8-bit RGBA bytes.
    func pixels(_ image: CGImage) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try #require(context.data), count: image.width * image.height * 4)
    }
}
