import MediaModel
import Testing

@Suite("Crop maths")
struct CropMathTests {
    let image = PixelSize(width: 1000, height: 800)
    let box = PixelRect(x: 100, y: 100, width: 400, height: 300)

    @Test func moveStaysInside() {
        let moved = CropMath.adjust(box, handle: .move, dx: 5000, dy: -5000, in: image, ratio: nil)
        #expect(moved == PixelRect(x: 600, y: 0, width: 400, height: 300))
    }

    @Test func edgeDragsResizeOneSide() {
        #expect(CropMath.adjust(box, handle: .right, dx: 50, dy: 0, in: image, ratio: nil) == PixelRect(x: 100, y: 100, width: 450, height: 300))
        #expect(CropMath.adjust(box, handle: .top, dx: 0, dy: -40, in: image, ratio: nil) == PixelRect(x: 100, y: 60, width: 400, height: 340))
    }

    @Test func dragsAreClampedToTheImage() {
        let grown = CropMath.adjust(box, handle: .topLeft, dx: -500, dy: -500, in: image, ratio: nil)
        #expect(grown == PixelRect(x: 0, y: 0, width: 500, height: 400))
    }

    @Test func boxNeverCollapses() {
        let squashed = CropMath.adjust(box, handle: .left, dx: 10_000, dy: 0, in: image, ratio: nil)
        #expect(squashed.width == CropMath.minimumSide)
        #expect(squashed.maxX == box.maxX)
    }

    @Test("Corner drags keep the aspect ratio", arguments: [CropHandle.topLeft, .topRight, .bottomLeft, .bottomRight])
    func cornersKeepRatio(_ handle: CropHandle) {
        let square = PixelRect(x: 200, y: 200, width: 200, height: 200)
        let result = CropMath.adjust(square, handle: handle, dx: 60, dy: 13, in: image, ratio: 1)
        #expect(result.width == result.height, "\(handle)")
        #expect(result.clamped(to: image) == result, "\(handle) must stay inside")
    }

    @Test func ratioShrinksToFit() {
        let result = CropMath.adjust(box, handle: .bottomRight, dx: 2000, dy: 0, in: image, ratio: 16.0 / 9)
        #expect(result.clamped(to: image) == result)
        #expect(abs(Double(result.width) / Double(result.height) - 16.0 / 9) < 0.01)
    }

    @Test func centredPresetIsTheLargestFit() {
        #expect(CropMath.centred(ratio: 1, in: image) == PixelRect(x: 100, y: 0, width: 800, height: 800))
        #expect(CropMath.centred(ratio: 16.0 / 9, in: image) == PixelRect(x: 0, y: 118, width: 1000, height: 563))
    }

    @Test func originalRatioMatchesTheImage() {
        #expect(CropAspect.original.ratio(for: image) == 1.25)
        #expect(CropAspect.free.ratio(for: image) == nil)
    }
}
