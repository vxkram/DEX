import MediaModel
import Testing

@Suite("Enhance planning")
struct EnhancementTests {
    static let writable: Set<ImageFormat> = [.jpeg, .png, .heic, .avif, .webp, .tiff, .gif]

    func info(_ format: ImageFormat, _ width: Int, _ height: Int, hdr: Bool = false) -> MediaInfo {
        MediaInfo(fileName: "a", fileSize: 1, typeIdentifier: format.typeIdentifier, format: format,
                  pixelWidth: width, pixelHeight: height, bitsPerComponent: 8, colorModel: "RGB", hasHDRGainMap: hdr)
    }

    @Test("Tiles cover every pixel exactly once", arguments: [(64, 48), (256, 256), (257, 900), (1155, 866), (224, 224)])
    func tilesCoverTheImage(_ width: Int, _ height: Int) {
        let size = PixelSize(width: width, height: height)
        var covered = [Int](repeating: 0, count: width * height)
        for tile in EnhanceTiling.tiles(for: size) {
            #expect(tile.window.width == 256 && tile.window.height == 256)
            // What's kept lies inside the window, and maps onto the target.
            #expect(tile.keep.x >= 0 && tile.keep.maxX <= 256 && tile.keep.y >= 0 && tile.keep.maxY <= 256)
            #expect(tile.window.x + tile.keep.x == tile.target.x && tile.window.y + tile.keep.y == tile.target.y)
            for y in tile.target.y..<tile.target.maxY {
                for x in tile.target.x..<tile.target.maxX { covered[y * width + x] += 1 }
            }
        }
        #expect(covered.allSatisfy { $0 == 1 })
    }

    @Test func innerEdgesKeepContext() {
        let tiles = EnhanceTiling.tiles(for: PixelSize(width: 1000, height: 300))
        // A tile that isn't at the image's left edge skips at least 16 px of context.
        for tile in tiles where tile.target.x > 0 { #expect(tile.keep.x >= 16) }
    }

    @Test func enhanceIsALossAndScalesTheOutput() throws {
        var request = ConvertRequest(target: .png)
        request.geometry.enhance = Enhancement(scale: 4, style: .best)
        let plan = try Planner.plan(info(.png, 640, 480), request, writable: Self.writable)
        #expect(plan.expectedWidth == 2560 && plan.expectedHeight == 1920)
        #expect(plan.verdict == .lossy)
        #expect(plan.notes.contains(.aiEnhanced(scale: 4, style: .best)))
        #expect(plan.enhance == request.geometry.enhance)
        #expect(plan.losslessAlternative == nil)
    }

    @Test func enhanceComesBeforeFitAndResize() throws {
        var request = ConvertRequest(target: .png)
        request.geometry = Geometry(crop: PixelRect(x: 0, y: 0, width: 200, height: 100),
                                    enhance: Enhancement(scale: 2), frame: Framing(ratio: 1),
                                    resize: PixelSize(width: 200, height: 200))
        let plan = try Planner.plan(info(.png, 400, 300), request, writable: Self.writable)
        #expect(plan.notes.contains(.framed(to: PixelSize(width: 400, height: 400), background: .white)))
        #expect(plan.notes.contains(.resampled(from: PixelSize(width: 400, height: 400), to: PixelSize(width: 200, height: 200))))
    }

    @Test func facesAndHDRAreDisclosed() throws {
        var request = ConvertRequest(target: .heic)
        request.geometry.enhance = Enhancement(faces: true)
        let plan = try Planner.plan(info(.heic, 1000, 800, hdr: true), request, writable: Self.writable)
        #expect(plan.notes.contains(.facesRestored))
        #expect(plan.notes.contains(.hdrNotKeptByEnhance))
        #expect(!plan.preservesHDR)
        #expect(request.geometry.enhance?.models == [.fastMedium, .faces])
    }

    @Test func tooLargeAResultIsRefused() {
        var request = ConvertRequest(target: .png)
        request.geometry.enhance = Enhancement(scale: 4)
        #expect(throws: PlanError.self) { try Planner.plan(info(.png, 6000, 6000), request, writable: Self.writable) }
    }

    @Test func noJPEGLosslessShortcut() throws {
        var request = ConvertRequest(target: .jpeg)
        request.geometry.enhance = Enhancement()
        let source = MediaInfo(fileName: "a", fileSize: 1, typeIdentifier: ImageFormat.jpeg.typeIdentifier, format: .jpeg,
                               pixelWidth: 400, pixelHeight: 300, bitsPerComponent: 8, colorModel: "RGB",
                               jpegBlockSize: PixelSize(width: 16, height: 16))
        #expect(try Planner.plan(source, request, writable: Self.writable).strategy == .reencode)
    }
}
