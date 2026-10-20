import MediaModel
import Testing

@Suite("Geometry planning")
struct GeometryPlannerTests {
    static let writable: Set<ImageFormat> = [.jpeg, .png, .heic, .avif, .webp, .tiff, .gif]

    func info(_ format: ImageFormat, width: Int = 4032, height: Int = 3024, orientation: Int = 1, hdr: Bool = false) -> MediaInfo {
        MediaInfo(
            fileName: "a", fileSize: 1, typeIdentifier: format.typeIdentifier, format: format,
            pixelWidth: width, pixelHeight: height, orientation: orientation, bitsPerComponent: 8,
            colorModel: "RGB", hasHDRGainMap: hdr,
            jpegBlockSize: format == .jpeg ? PixelSize(width: 16, height: 16) : nil
        )
    }

    func plan(_ source: MediaInfo, _ target: ImageFormat, _ geometry: Geometry) throws -> ConversionPlan {
        try Planner.plan(source, ConvertRequest(target: target, metadata: .keepAll, geometry: geometry), writable: Self.writable)
    }

    // MARK: Orientation algebra

    @Test func exifRoundTrips() {
        for exif in 1...8 { #expect(Orientation(exif: exif).exif == exif) }
    }

    @Test func inverseUndoes() {
        for exif in 1...8 {
            let o = Orientation(exif: exif)
            #expect(o.followed(by: o.inverse).isIdentity, "\(exif)")
            #expect(o.inverse.followed(by: o).isIdentity, "\(exif)")
        }
    }

    @Test func quarterTurnsCompose() {
        var g = Geometry()
        for _ in 0..<4 { g.rotateClockwise() }
        #expect(g.orientation.isIdentity)
        g.rotateClockwise()
        g.rotateCounterclockwise()
        #expect(g.orientation.isIdentity)
        g.flipHorizontally()
        g.flipHorizontally()
        #expect(g.orientation.isIdentity)
    }

    // MARK: Rotate / flip

    @Test("Rotating JPEG/HEIC/TIFF only rewrites the orientation tag", arguments: [ImageFormat.jpeg, .heic, .tiff])
    func rotationIsMetadataOnly(_ format: ImageFormat) throws {
        var geometry = Geometry()
        geometry.rotateClockwise()
        let result = try plan(info(format, orientation: 6), format, geometry)
        #expect(result.strategy == .rewriteMetadata)
        #expect(result.verdict == .noReencode)
        #expect(result.outputOrientation == 3)  // 90° + 90°
        #expect(result.expectedWidth == 4032 && result.expectedHeight == 3024)
    }

    @Test func rotatingAVIFBakesPixels() throws {
        var geometry = Geometry()
        geometry.rotateClockwise()
        let result = try plan(info(.avif), .avif, geometry)
        #expect(result.strategy == .reencode)
        #expect(result.bakedOrientation == 6)
        #expect(result.outputOrientation == 1)
        #expect(result.expectedWidth == 3024 && result.expectedHeight == 4032)
    }

    // MARK: Crop

    @Test func jpegCropIsLosslessAndSnapsToBlocks() throws {
        let crop = PixelRect(x: 100, y: 50, width: 1000, height: 800)
        let result = try plan(info(.jpeg), .jpeg, Geometry(crop: crop))
        #expect(result.strategy == .losslessJPEGTransform)
        #expect(result.verdict == .noReencode)
        let snapped = PixelRect(x: 96, y: 48, width: 1004, height: 802)
        #expect(result.pixelCrop == snapped)
        #expect(result.displayCrop == snapped)
        #expect(result.notes.contains(.cropSnapped(to: snapped)))
        #expect(result.expectedWidth == 1004 && result.expectedHeight == 802)
    }

    @Test func alignedJPEGCropNeedsNoNote() throws {
        let crop = PixelRect(x: 160, y: 320, width: 1000, height: 800)
        let result = try plan(info(.jpeg), .jpeg, Geometry(crop: crop))
        #expect(result.pixelCrop == crop)
        #expect(result.notes.isEmpty)
    }

    @Test func rotatedJPEGCropMapsToStoredPixels() throws {
        // Stored 4032×3024 with orientation 6: displayed 3024×4032.
        let crop = PixelRect(x: 0, y: 0, width: 1024, height: 2048)
        let result = try plan(info(.jpeg, orientation: 6), .jpeg, Geometry(crop: crop))
        #expect(result.strategy == .losslessJPEGTransform)
        #expect(result.outputOrientation == 6)
        #expect(result.pixelCrop == PixelRect(x: 0, y: 2000, width: 2048, height: 1024))
        #expect(result.outputDisplaySize == PixelSize(width: 1024, height: 2048))
    }

    @Test func exactJPEGCropReencodes() throws {
        let crop = PixelRect(x: 100, y: 50, width: 1000, height: 800)
        let result = try plan(info(.jpeg), .jpeg, Geometry(crop: crop, exactCrop: true))
        #expect(result.strategy == .reencode)
        #expect(result.verdict == .lossy)
        #expect(result.pixelCrop == crop)
        #expect(result.losslessAlternative == .png)
    }

    @Test func jpegCropWithHDRDisclosesTheLoss() throws {
        let result = try plan(info(.jpeg, hdr: true), .jpeg, Geometry(crop: PixelRect(x: 0, y: 0, width: 512, height: 512)))
        #expect(result.verdict == .lossy)
        #expect(result.notes.contains(.hdrNotKeptByLosslessCrop))
    }

    @Test func pngCropIsLossless() throws {
        let crop = PixelRect(x: 7, y: 3, width: 101, height: 99)
        let result = try plan(info(.png, width: 400, height: 300), .png, Geometry(crop: crop))
        #expect(result.verdict == .lossless)
        #expect(result.pixelCrop == crop)
        #expect(result.expectedWidth == 101 && result.expectedHeight == 99)
    }

    @Test func heicCropOffersALosslessAlternative() throws {
        let result = try plan(info(.heic), .heic, Geometry(crop: PixelRect(x: 1, y: 1, width: 100, height: 100)))
        #expect(result.verdict == .lossy)
        #expect(result.losslessAlternative == .png)
    }

    @Test func fullFrameCropIsNoCrop() throws {
        let result = try plan(info(.png, width: 400, height: 300), .png, Geometry(crop: PixelRect(x: 0, y: 0, width: 400, height: 300)))
        #expect(result.strategy == .copyFile)
    }

    @Test func cropIsClampedToTheImage() throws {
        let result = try plan(info(.png, width: 400, height: 300), .png, Geometry(crop: PixelRect(x: 300, y: 200, width: 500, height: 500)))
        #expect(result.pixelCrop == PixelRect(x: 300, y: 200, width: 100, height: 100))
    }

    // MARK: Resize

    @Test func resizeIsAlwaysDisclosedAsResampling() throws {
        let result = try plan(info(.png, width: 400, height: 300), .png, Geometry(resize: PixelSize(width: 200, height: 150)))
        #expect(result.verdict == .lossy)
        #expect(result.notes.contains(.resampled(from: PixelSize(width: 400, height: 300), to: PixelSize(width: 200, height: 150))))
        #expect(result.losslessAlternative == nil)
        #expect(result.expectedWidth == 200 && result.expectedHeight == 150)
    }

    @Test func resizeToTheSameSizeIsNotAResize() throws {
        let result = try plan(info(.png, width: 400, height: 300), .png, Geometry(resize: PixelSize(width: 400, height: 300)))
        #expect(result.strategy == .copyFile)
    }

    @Test func cropThenResize() throws {
        let geometry = Geometry(crop: PixelRect(x: 0, y: 0, width: 200, height: 100), resize: PixelSize(width: 100, height: 50))
        let result = try plan(info(.jpeg, width: 400, height: 300), .jpeg, geometry)
        #expect(result.strategy == .reencode)
        #expect(result.notes.contains(.resampled(from: PixelSize(width: 200, height: 100), to: PixelSize(width: 100, height: 50))))
        #expect(result.expectedWidth == 100 && result.expectedHeight == 50)
    }
}
