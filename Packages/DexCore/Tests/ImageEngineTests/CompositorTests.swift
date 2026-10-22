import CoreGraphics
import Foundation
@testable import ImageEngine
import ImageIO
import MediaModel
import Testing

@Suite("Compositor")
struct CompositorTests {
    let fixtures: FixtureFactory

    init() throws {
        fixtures = try FixtureFactory()
    }

    func composed(_ url: URL) throws -> ComposedImage {
        ComposedImage(url: url, info: try ImageEngine.inspect(url: url))
    }

    func solid(_ format: ImageFormat, _ name: String, _ w: Int, _ h: Int, _ rgb: (Double, Double, Double), alpha: Bool = false) async throws -> URL {
        var spec = FixtureFactory.Spec()
        spec.width = w
        spec.height = h
        spec.solid = rgb
        spec.alpha = alpha
        if format == .webp {
            let png = try await fixtures.image(.png, named: "\(name)-src.png", spec)
            let (_, plan) = try ImageEngine.plan(png, ConvertRequest(target: .webp))
            let url = fixtures.directory.appendingPathComponent("\(name).webp")
            try await ImageEngine.convert(png, plan: plan, to: url)
            return url
        }
        return try await fixtures.image(format, named: "\(name).\(format.preferredFileExtension)", spec)
    }

    func run(_ source: URL, _ request: ConvertRequest) async throws -> (URL, ConversionPlan) {
        let (_, plan) = try ImageEngine.plan(source, request)
        let output = fixtures.directory.appendingPathComponent("out-\(UUID().uuidString).\(request.target.preferredFileExtension)")
        try await ImageEngine.convert(source, plan: plan, to: output)
        return (output, plan)
    }

    /// sRGB 8-bit colour at a top-left pixel coordinate.
    func color(_ url: URL, x: Int, y: Int) throws -> (Int, Int, Int) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let p = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let i = (y * image.width + x) * 4
        return (Int(p[i]), Int(p[i + 1]), Int(p[i + 2]))
    }

    func close(_ a: (Int, Int, Int), _ b: (Int, Int, Int), tolerance: Int = 4) -> Bool {
        abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
    }

    @Test func jpegAndWebPSideBySide() async throws {
        defer { fixtures.cleanUp() }
        let red = try await solid(.jpeg, "red", 60, 40, (1, 0, 0))
        let blue = try await solid(.webp, "blue", 120, 80, (0, 0, 1))
        let arrangement = Arrangement(layout: .horizontal, images: [try composed(blue)], spacing: 10, background: .white)

        let (output, plan) = try await run(red, ConvertRequest(target: .png, composition: .arrangement(arrangement)))
        let info = try ImageEngine.inspect(url: output)
        #expect(info.pixelWidth == 130 && info.pixelHeight == 40)  // 60 + 10 + 60 (blue scaled to 40 high)
        #expect(plan.notes.contains(.imageResampled(name: "blue.webp", to: PixelSize(width: 60, height: 40))))
        #expect(close(try color(output, x: 30, y: 20), (255, 0, 0), tolerance: 8))   // JPEG red
        #expect(close(try color(output, x: 65, y: 20), (255, 255, 255)))            // gap
        #expect(close(try color(output, x: 100, y: 20), (0, 0, 255)))               // WebP blue
    }

    @Test func theOpenedImageCanSitAnywhere() async throws {
        defer { fixtures.cleanUp() }
        let base = try await solid(.png, "base", 40, 40, (1, 0, 0))
        let first = try await solid(.jpeg, "first", 40, 40, (0, 0, 1))
        let last = try await solid(.webp, "last", 40, 40, (0, 1, 0))
        let arrangement = Arrangement(layout: .horizontal, images: [try composed(first), try composed(last)], basePosition: 1)
        let (output, plan) = try await run(base, ConvertRequest(target: .png, composition: .arrangement(arrangement)))
        #expect(plan.expectedWidth == 120)
        #expect(close(try color(output, x: 20, y: 20), (0, 0, 255), tolerance: 8))   // first
        #expect(close(try color(output, x: 60, y: 20), (255, 0, 0)))                 // base in the middle
        #expect(close(try color(output, x: 100, y: 20), (0, 255, 0)))                // last
    }

    @Test func stackedKeepsEachImagesPixels() async throws {
        defer { fixtures.cleanUp() }
        let top = try await solid(.png, "top", 50, 20, (0, 1, 0))
        let bottom = try await solid(.png, "bottom", 50, 30, (1, 1, 0))
        let arrangement = Arrangement(layout: .vertical, images: [try composed(bottom)])
        let (output, plan) = try await run(top, ConvertRequest(target: .png, composition: .arrangement(arrangement)))
        #expect(plan.verdict == .lossless)
        let info = try ImageEngine.inspect(url: output)
        #expect(info.pixelWidth == 50 && info.pixelHeight == 50)
        #expect(try color(output, x: 25, y: 10) == (0, 255, 0))
        #expect(try color(output, x: 25, y: 40) == (255, 255, 0))
    }

    @Test func layerLandsWhereItIsPlaced() async throws {
        defer { fixtures.cleanUp() }
        let base = try await solid(.jpeg, "base", 200, 100, (1, 1, 1))
        let logo = try await solid(.webp, "logo", 40, 20, (0, 0, 1))
        let layer = OverlayLayer(image: try composed(logo), centerX: 150, centerY: 30, width: 40)
        let (output, _) = try await run(base, ConvertRequest(target: .png, composition: .layers([layer])))
        #expect(close(try color(output, x: 150, y: 30), (0, 0, 255)))      // inside the logo
        #expect(close(try color(output, x: 40, y: 70), (255, 255, 255)))   // untouched base
    }

    @Test func layerOpacityBlends() async throws {
        defer { fixtures.cleanUp() }
        let base = try await solid(.png, "base", 100, 100, (1, 1, 1))
        let logo = try await solid(.png, "logo", 50, 50, (0, 0, 0))
        let layer = OverlayLayer(image: try composed(logo), centerX: 50, centerY: 50, width: 50, opacity: 0.5)
        let (output, _) = try await run(base, ConvertRequest(target: .png, composition: .layers([layer])))
        let mid = try color(output, x: 50, y: 50)
        #expect((100...160).contains(mid.0), "half-transparent black on white is mid grey, got \(mid)")
    }

    @Test func transparentPNGLogoOnJPEG() async throws {
        defer { fixtures.cleanUp() }
        let base = try await solid(.jpeg, "photo", 100, 100, (1, 1, 1))
        let logo = try await solid(.png, "logo", 40, 40, (1, 0, 0), alpha: true)
        let layer = OverlayLayer(image: try composed(logo), centerX: 50, centerY: 50, width: 40)
        let (output, plan) = try await run(base, ConvertRequest(target: .jpeg, composition: .layers([layer])))
        #expect(!plan.notes.contains(.transparencyFlattened))
        let pixel = try color(output, x: 50, y: 50)
        #expect(pixel.0 > 240 && pixel.1 < 160, "50% red over white is pink, got \(pixel)")
    }

    @Test func compositeCanBeResized() async throws {
        defer { fixtures.cleanUp() }
        let a = try await solid(.png, "a", 100, 100, (1, 0, 0))
        let b = try await solid(.png, "b", 100, 100, (0, 1, 0))
        let request = ConvertRequest(
            target: .png, geometry: Geometry(resize: PixelSize(width: 100, height: 50)),
            composition: .arrangement(Arrangement(layout: .horizontal, images: [try composed(b)]))
        )
        let (output, _) = try await run(a, request)
        let info = try ImageEngine.inspect(url: output)
        #expect(info.pixelWidth == 100 && info.pixelHeight == 50)
    }

    @Test func canvasPlacesTheBaseAndTurnsALayer() async throws {
        defer { fixtures.cleanUp() }
        let base = try await solid(.png, "base", 100, 50, (1, 0, 0))
        let bar = try await solid(.png, "bar", 80, 10, (0, 0, 1))
        // Base in the top-left quarter; a bar turned upright on the right.
        let page = Canvas(size: PixelSize(width: 200, height: 200), background: .black,
                          base: LayerPlacement(centerX: 50, centerY: 25, width: 100),
                          layers: [OverlayLayer(image: try composed(bar), centerX: 150, centerY: 100, width: 80, rotation: 90)])
        let (output, _) = try await run(base, ConvertRequest(target: .png, composition: .canvas(page)))
        let info = try ImageEngine.inspect(url: output)
        #expect(info.pixelWidth == 200 && info.pixelHeight == 200)
        #expect(close(try color(output, x: 50, y: 25), (255, 0, 0)))     // the base
        #expect(close(try color(output, x: 50, y: 150), (0, 0, 0)))      // background
        #expect(close(try color(output, x: 150, y: 70), (0, 0, 255)))    // the turned bar, vertical now
        #expect(close(try color(output, x: 130, y: 100), (0, 0, 0)))     // beside it
    }

    @Test func canvasStacksTheBaseWhereAsked() async throws {
        defer { fixtures.cleanUp() }
        let base = try await solid(.png, "base", 100, 100, (1, 0, 0))
        let cover = try await solid(.png, "cover", 100, 100, (0, 1, 0))
        var page = Canvas(size: PixelSize(width: 100, height: 100), base: LayerPlacement(centerX: 50, centerY: 50, width: 100),
                          layers: [OverlayLayer(image: try composed(cover), centerX: 50, centerY: 50, width: 100)])
        let (below, _) = try await run(base, ConvertRequest(target: .png, composition: .canvas(page)))
        #expect(close(try color(below, x: 50, y: 50), (0, 255, 0)))
        page.basePosition = 1
        let (above, _) = try await run(base, ConvertRequest(target: .png, composition: .canvas(page)))
        #expect(close(try color(above, x: 50, y: 50), (255, 0, 0)))
    }
}
