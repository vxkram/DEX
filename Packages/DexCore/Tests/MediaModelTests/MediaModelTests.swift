import MediaModel
import Testing

@Suite("MediaModel")
struct MediaModelTests {
    @Test("Every format round-trips through its type identifier", arguments: ImageFormat.allCases)
    func typeIdentifierRoundTrip(_ format: ImageFormat) {
        #expect(ImageFormat(typeIdentifier: format.typeIdentifier) == format)
    }

    @Test func sequenceTypesMapToStillFormats() {
        #expect(ImageFormat(typeIdentifier: "public.heics") == .heic)
        #expect(ImageFormat(typeIdentifier: "public.avis") == .avif)
        #expect(ImageFormat(typeIdentifier: "com.adobe.photoshop-image") == nil)
    }

    @Test("Display size swaps only for 90° orientations", arguments: 1...8)
    func displaySize(_ orientation: Int) {
        let info = MediaInfo(
            fileName: "a.jpg", fileSize: 1, typeIdentifier: "public.jpeg", format: .jpeg,
            pixelWidth: 400, pixelHeight: 300, orientation: orientation
        )
        let swapped = orientation >= 5
        #expect(info.displayWidth == (swapped ? 300 : 400))
        #expect(info.displayHeight == (swapped ? 400 : 300))
    }

    @Test func jpegIsNeverLosslessOrTransparent() {
        #expect(!ImageFormat.jpeg.supportsLossless)
        #expect(!ImageFormat.jpeg.supportsAlpha)
        #expect(ImageFormat.png.supportsLossless)
    }
}
