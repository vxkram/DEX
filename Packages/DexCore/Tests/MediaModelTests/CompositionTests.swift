import Foundation
import MediaModel
import Testing

@Suite("Composition planning")
struct CompositionTests {
    static let writable: Set<ImageFormat> = [.jpeg, .png, .heic, .avif, .webp, .tiff, .gif]

    func info(_ format: ImageFormat, _ width: Int, _ height: Int, alpha: Bool = false, hdr: Bool = false) -> MediaInfo {
        MediaInfo(fileName: "\(format.rawValue).\(format.preferredFileExtension)", fileSize: 1,
                  typeIdentifier: format.typeIdentifier, format: format, pixelWidth: width, pixelHeight: height,
                  bitsPerComponent: 8, colorModel: "RGB", hasAlpha: alpha, hasHDRGainMap: hdr)
    }

    func image(_ format: ImageFormat, _ width: Int, _ height: Int, alpha: Bool = false) -> ComposedImage {
        ComposedImage(url: URL(fileURLWithPath: "/tmp/\(UUID()).\(format.preferredFileExtension)"),
                      info: info(format, width, height, alpha: alpha))
    }

    func arrangement(_ layout: Arrangement.Layout, _ images: [ComposedImage], sizing: Arrangement.Sizing = .matchSmallest,
                     spacing: Int = 0, background: Arrangement.Background = .white) -> Arrangement {
        Arrangement(layout: layout, images: images, spacing: spacing, sizing: sizing, background: background)
    }

    // MARK: Layout maths

    @Test func sideBySideMatchesTheSmallestHeight() {
        let result = ArrangementLayout.layout(
            [PixelSize(width: 400, height: 300), PixelSize(width: 800, height: 600)],
            arrangement(.horizontal, [], spacing: 10)
        )
        #expect(result.canvas == PixelSize(width: 810, height: 300))
        #expect(result.frames == [PixelRect(x: 0, y: 0, width: 400, height: 300), PixelRect(x: 410, y: 0, width: 400, height: 300)])
    }

    @Test func stackedMatchesTheSmallestWidth() {
        let result = ArrangementLayout.layout(
            [PixelSize(width: 400, height: 300), PixelSize(width: 800, height: 400)],
            arrangement(.vertical, [])
        )
        #expect(result.canvas == PixelSize(width: 400, height: 500))
        #expect(result.frames[1] == PixelRect(x: 0, y: 300, width: 400, height: 200))
    }

    @Test func originalSizesAreCentred() {
        let result = ArrangementLayout.layout(
            [PixelSize(width: 100, height: 100), PixelSize(width: 100, height: 50)],
            arrangement(.horizontal, [], sizing: .original)
        )
        #expect(result.canvas == PixelSize(width: 200, height: 100))
        #expect(result.frames[1] == PixelRect(x: 100, y: 25, width: 100, height: 50))
    }

    @Test func gridWrapsIntoRows() {
        let sizes = Array(repeating: PixelSize(width: 100, height: 100), count: 5)
        let result = ArrangementLayout.layout(sizes, arrangement(.grid(columns: 2), [], spacing: 4))
        #expect(result.canvas == PixelSize(width: 204, height: 308))
        #expect(result.frames[4] == PixelRect(x: 52, y: 208, width: 100, height: 100))
    }

    // MARK: Planning

    @Test func mixedFormatsCombineIntoOnePicture() throws {
        let extra = image(.webp, 400, 300)
        let request = ConvertRequest(target: .png, composition: .arrangement(arrangement(.horizontal, [extra])))
        let plan = try Planner.plan(info(.jpeg, 400, 300), request, writable: Self.writable)
        #expect(plan.strategy == .reencode)
        #expect(plan.verdict == .lossless)  // same heights: nothing scaled
        #expect(plan.expectedWidth == 800 && plan.expectedHeight == 300)
        #expect(plan.notes.contains(.composited(images: 1)))
    }

    @Test func scaledImagesAreDisclosed() throws {
        let extra = image(.webp, 800, 600)
        let request = ConvertRequest(target: .png, composition: .arrangement(arrangement(.horizontal, [extra])))
        let plan = try Planner.plan(info(.jpeg, 400, 300), request, writable: Self.writable)
        #expect(plan.verdict == .lossy)
        #expect(plan.notes.contains(.imageResampled(name: extra.info.fileName, to: PixelSize(width: 400, height: 300))))
    }

    @Test func overlayKeepsTheBaseSize() throws {
        let logo = image(.png, 200, 100, alpha: true)
        let layer = OverlayLayer(image: logo, centerX: 300, centerY: 200, width: 200)
        let plan = try Planner.plan(info(.jpeg, 1200, 800), ConvertRequest(target: .jpeg, composition: .layers([layer])),
                                    writable: Self.writable)
        #expect(plan.expectedWidth == 1200 && plan.expectedHeight == 800)
        #expect(!plan.notes.contains { if case .imageResampled = $0 { true } else { false } })
        #expect(plan.notes.contains(.transparencyFlattened) == false, "base is opaque; only the logo has alpha, drawn onto it")
    }

    @Test func transparentBackgroundNeedsAlpha() throws {
        let extra = image(.jpeg, 100, 50)
        let arrangementWithGap = arrangement(.horizontal, [extra], sizing: .original, background: .transparent)
        let plan = try Planner.plan(info(.jpeg, 100, 100), ConvertRequest(target: .jpeg, composition: .arrangement(arrangementWithGap)),
                                    writable: Self.writable)
        #expect(plan.notes.contains(.transparencyFlattened))
        #expect(plan.losslessAlternative == .png)
    }

    @Test func hdrIsDisclosed() throws {
        var hdr = image(.heic, 100, 100)
        hdr.info.hasHDRGainMap = true
        let plan = try Planner.plan(info(.jpeg, 100, 100), ConvertRequest(target: .heic, composition: .arrangement(arrangement(.horizontal, [hdr]))),
                                    writable: Self.writable)
        #expect(plan.notes.contains(.hdrNotKeptInComposite))
        #expect(!plan.preservesHDR)
    }

    @Test func placedLayerNeverEnlarges() {
        let small = image(.png, 120, 60)
        let layer = OverlayLayer.placed(small, on: PixelSize(width: 4000, height: 3000))
        #expect(layer.width == 120)
        #expect(!layer.isResampled)
        let big = OverlayLayer.placed(image(.png, 3000, 1500), on: PixelSize(width: 1000, height: 1000))
        #expect(big.width == 400)
    }
}
