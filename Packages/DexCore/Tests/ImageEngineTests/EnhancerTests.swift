import CoreGraphics
import Foundation
@testable import ImageEngine
import ImageIO
import MediaModel
import Testing

@Suite("Enhancer")
struct EnhancerTests {
    @Test func similarityRecoversATransform() {
        let truth = CGAffineTransform(rotationAngle: 0.3).scaledBy(x: 1.7, y: 1.7).translatedBy(x: 40, y: -12)
        let points = [CGPoint(x: 10, y: 20), CGPoint(x: 80, y: 25), CGPoint(x: 45, y: 60), CGPoint(x: 20, y: 90), CGPoint(x: 70, y: 92)]
        let found = Enhancer.similarity(from: points, to: points.map { $0.applying(truth) })
        for p in points {
            let a = p.applying(found), b = p.applying(truth)
            #expect(abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6)
        }
    }

    @Test func missingModelIsReported() throws {
        let image = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        guard ProcessInfo.processInfo.environment["DEX_MODELS_DIR"] == nil else { return }
        #expect(throws: EnhanceError.self) { try Enhancer.enhance(image, Enhancement(style: .anime)) }
    }

    // MARK: Real models: `make test-models` (needs the zips of the models-1 release)

    static var modelsAvailable: Bool { ProcessInfo.processInfo.environment["DEX_MODELS_DIR"] != nil }

    @Test(.enabled(if: modelsAvailable)) func upscalesEveryStyle() async throws {
        let fixtures = try FixtureFactory()
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.width = 300
        spec.height = 200
        spec.noise = true
        let source = try await fixtures.image(.jpeg, spec)
        for style in Enhancement.Style.allCases {
            for scale in [2, 4] {
                var request = ConvertRequest(target: .png)
                request.geometry.enhance = Enhancement(scale: scale, style: style)
                let (_, plan) = try ImageEngine.plan(source, request)
                let output = fixtures.directory.appendingPathComponent("\(style)-\(scale).png")
                try await ImageEngine.convert(source, plan: plan, to: output)
                let info = try ImageEngine.inspect(url: output)
                #expect(info.pixelWidth == 300 * scale && info.pixelHeight == 200 * scale, "\(style) \(scale)×")
            }
        }
    }

    @Test(.enabled(if: modelsAvailable)) func keepsTheColours() async throws {
        // A flat colour stays that colour: the model sharpens, it doesn't recolour.
        let fixtures = try FixtureFactory()
        defer { fixtures.cleanUp() }
        var spec = FixtureFactory.Spec()
        spec.width = 300
        spec.height = 300
        spec.solid = (0.8, 0.3, 0.1)
        let source = try await fixtures.image(.png, spec)
        let image = try #require(CGImageSourceCreateWithURL(source as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let result = try Enhancer.enhance(image, Enhancement(scale: 4, style: .fast))
        #expect(result.width == 1200 && result.height == 1200)
        let pixel = try rgb(result, x: 600, y: 600)
        #expect(abs(pixel.0 - 204) < 6 && abs(pixel.1 - 77) < 6 && abs(pixel.2 - 26) < 6, "\(pixel)")
        // Tile seams would show as a step at a tile boundary (every 224 px of the source).
        let left = try rgb(result, x: 224 * 4 - 1, y: 600), right = try rgb(result, x: 224 * 4, y: 600)
        #expect(abs(left.0 - right.0) < 4 && abs(left.1 - right.1) < 4 && abs(left.2 - right.2) < 4)
    }

    func rgb(_ image: CGImage, x: Int, y: Int) throws -> (Int, Int, Int) {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let i = (y * image.width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }
}
