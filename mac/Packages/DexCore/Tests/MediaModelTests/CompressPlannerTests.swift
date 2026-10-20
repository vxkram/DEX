import MediaModel
import Testing

@Suite("Compression planning")
struct CompressPlannerTests {
    static let writable: Set<ImageFormat> = [.jpeg, .png, .heic, .avif, .webp, .tiff, .gif]

    func info(_ format: ImageFormat, hdr: Bool = false) -> MediaInfo {
        MediaInfo(
            fileName: "a", fileSize: 1, typeIdentifier: format.typeIdentifier, format: format,
            pixelWidth: 400, pixelHeight: 300, bitsPerComponent: 8, colorModel: "RGB", hasHDRGainMap: hdr,
            jpegBlockSize: format == .jpeg ? PixelSize(width: 16, height: 16) : nil
        )
    }

    func plan(_ format: ImageFormat, optimize: Bool = true, quality: QualityPreference = .maximum, target: ImageFormat? = nil, hdr: Bool = false) throws -> ConversionPlan {
        try Planner.plan(info(format, hdr: hdr),
                         ConvertRequest(target: target ?? format, quality: quality, metadata: .keepAll, optimize: optimize),
                         writable: Self.writable)
    }

    @Test func jpegIsRepackedWithoutDecoding() throws {
        let result = try plan(.jpeg)
        #expect(result.strategy == .losslessJPEGTransform)
        #expect(result.verdict == .noReencode)
        #expect(result.pixelCrop == nil)
        #expect(result.notes == [.optimisedLosslessly])
    }

    @Test("PNG and TIFF are re-compressed losslessly", arguments: [ImageFormat.png, .tiff])
    func losslessRecompression(_ format: ImageFormat) throws {
        let result = try plan(format)
        #expect(result.strategy == .reencode)
        #expect(result.verdict == .lossless)
        #expect(result.notes.contains(.optimisedLosslessly))
    }

    @Test("Formats without a lossless repack are left alone", arguments: [ImageFormat.heic, .avif, .gif])
    func noRepackMeansNoReencode(_ format: ImageFormat) throws {
        let result = try plan(format)
        #expect(result.strategy == .copyFile)
        #expect(result.verdict == .noReencode)
    }

    @Test func optimisingHDRJPEGDisclosesTheGainMap() throws {
        let result = try plan(.jpeg, hdr: true)
        #expect(result.verdict == .lossy)
        #expect(result.notes.contains(.hdrNotKeptByLosslessCrop))
    }

    @Test func lowerQualityReencodesTheSameFormat() throws {
        let result = try plan(.jpeg, optimize: false, quality: .custom(0.7))
        #expect(result.strategy == .reencode)
        #expect(result.lossyQuality == 0.7)
        #expect(result.verdict == .lossy)
    }

    @Test func optimiseDoesNothingAcrossFormats() throws {
        let result = try plan(.png, target: .jpeg)
        #expect(!result.notes.contains(.optimisedLosslessly))
    }
}
