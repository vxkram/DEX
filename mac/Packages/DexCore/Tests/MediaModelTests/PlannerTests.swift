import MediaModel
import Testing

@Suite("Planner")
struct PlannerTests {
    static let allWritable: Set<ImageFormat> = [.jpeg, .png, .heic, .avif, .webp, .tiff, .gif]

    func info(
        _ format: ImageFormat,
        depth: Int = 8,
        alpha: Bool = false,
        hdr: Bool = false,
        frames: Int = 1,
        gps: Bool = false,
        size: Int = 100
    ) -> MediaInfo {
        MediaInfo(
            fileName: "a.\(format.preferredFileExtension)", fileSize: 1_000,
            typeIdentifier: format.typeIdentifier, format: format,
            pixelWidth: size, pixelHeight: size / 2,
            bitsPerComponent: depth, hasAlpha: alpha, hasHDRGainMap: hdr,
            frameCount: frames, hasGPS: gps
        )
    }

    func plan(_ source: MediaInfo, to target: ImageFormat, metadata: MetadataPolicy = .removeLocation) throws -> ConversionPlan {
        try Planner.plan(source, ConvertRequest(target: target, metadata: metadata), writable: Self.allWritable)
    }

    // MARK: Same format

    @Test("Same format with nothing to change is a plain copy", arguments: [ImageFormat.jpeg, .png, .heic, .avif, .tiff, .gif])
    func sameFormatCopies(_ format: ImageFormat) throws {
        let result = try plan(info(format), to: format)
        #expect(result.strategy == .copyFile)
        #expect(result.verdict == .noReencode)
        #expect(result.notes.isEmpty)
    }

    @Test("Removing location never re-encodes where ImageIO allows it", arguments: [ImageFormat.jpeg, .heic, .tiff])
    func locationRemovalRewritesMetadata(_ format: ImageFormat) throws {
        let result = try plan(info(format, gps: true), to: format)
        #expect(result.strategy == .rewriteMetadata)
        #expect(result.verdict == .noReencode)
        #expect(result.notes == [.locationRemoved])
    }

    @Test("Lossless codecs strip metadata by a lossless re-encode", arguments: [ImageFormat.png, .gif])
    func losslessCodecsReencodeWithoutLoss(_ format: ImageFormat) throws {
        let result = try plan(info(format, gps: true), to: format, metadata: .removeAll)
        #expect(result.strategy == .reencode)
        #expect(result.verdict == .lossless)
        #expect(result.notes == [.allMetadataRemoved])
    }

    @Test func avifTargetAppliesRotationToPixels() throws {
        var source = info(.heic, size: 400)
        source.orientation = 6
        let result = try plan(source, to: .avif)
        #expect(result.appliesOrientation)
        #expect(result.notes.contains(.orientationApplied))
        #expect(result.expectedWidth == 200 && result.expectedHeight == 400)

        #expect(try !plan(source, to: .jpeg).appliesOrientation)
        source.orientation = 1
        #expect(try !plan(source, to: .avif).appliesOrientation)
    }

    @Test func avifLocationRemovalIsHonestAboutReencoding() throws {
        let result = try plan(info(.avif, gps: true), to: .avif)
        #expect(result.strategy == .reencode)
        #expect(result.verdict == .lossy)
        #expect(result.notes.first == .metadataEditRequiresReencode(.avif))
        #expect(result.notes.contains(.locationRemoved))
        #expect(result.losslessAlternative == .png)

        // Keeping location avoids the re-encode entirely.
        #expect(try plan(info(.avif, gps: true), to: .avif, metadata: .keepAll).verdict == .noReencode)
    }

    // MARK: Cross-format

    @Test func heicToJPEGIsLossyAtMaximumQuality() throws {
        let result = try plan(info(.heic), to: .jpeg)
        #expect(result.verdict == .lossy)
        #expect(result.lossyQuality == QualityPreference.maximumLossyQuality)
        #expect(result.notes == [.lossyEncode(.jpeg, quality: 0.95)])
        #expect(result.losslessAlternative == .png)
    }

    @Test func lossyToLosslessIsLosslessButLarger() throws {
        let result = try plan(info(.jpeg), to: .png)
        #expect(result.verdict == .lossless)
        #expect(result.lossyQuality == nil)
        #expect(result.notes == [.noAdditionalLoss])
        #expect(result.losslessAlternative == nil)
    }

    @Test func losslessToLosslessHasNoNotes() throws {
        let result = try plan(info(.png, depth: 16, alpha: true), to: .tiff)
        #expect(result.verdict == .lossless)
        #expect(result.notes.isEmpty)
    }

    @Test func transparencyToJPEGIsFlattened() throws {
        let result = try plan(info(.png, alpha: true), to: .jpeg)
        #expect(result.notes.contains(.transparencyFlattened))
        #expect(result.losslessAlternative == .png)
    }

    @Test func sixteenBitToHEICDropsToTenBit() throws {
        let result = try plan(info(.png, depth: 16), to: .heic)
        #expect(result.notes.contains(.bitDepthReduced(from: 16, to: 10)))
    }

    @Test func toGIFIsPaletteLimited() throws {
        let result = try plan(info(.png), to: .gif)
        #expect(result.verdict == .lossy)
        #expect(result.notes.contains(.paletteLimited))
        #expect(result.lossyQuality == nil)
    }

    @Test func animationToStillKeepsFirstFrameAndHasNoLosslessEscape() throws {
        let result = try plan(info(.gif, frames: 5), to: .png)
        #expect(result.verdict == .lossy)
        #expect(result.notes.contains(.animationFirstFrameOnly(frames: 5)))
        #expect(result.expectedFrameCount == 1)
        #expect(result.losslessAlternative == nil)
    }

    @Test func gifToGIFKeepsAllFrames() throws {
        let result = try plan(info(.gif, frames: 5), to: .gif, metadata: .removeAll)
        #expect(result.expectedFrameCount == 5)
        #expect(result.verdict == .lossless)
    }

    @Test func hdrIsKeptWhereTheFormatAllowsIt() throws {
        for target in [ImageFormat.jpeg, .heic, .avif] {
            let result = try plan(info(.heic, hdr: true), to: target)
            #expect(result.preservesHDR, "\(target)")
            #expect(!result.notes.contains(.hdrDropped(to: target)))
        }
    }

    @Test func hdrIsNeverDroppedSilently() throws {
        for target in [ImageFormat.png, .tiff, .gif] {
            let result = try plan(info(.heic, hdr: true), to: target)
            #expect(result.verdict == .lossy)
            #expect(!result.preservesHDR)
            #expect(result.notes.contains(.hdrDropped(to: target)))
        }
    }

    @Test func geometryIsAlwaysPreserved() throws {
        let result = try plan(info(.heic, size: 4032), to: .jpeg)
        #expect(result.expectedWidth == 4032)
        #expect(result.expectedHeight == 2016)
    }

    // MARK: Metadata notes

    @Test func locationNoteOnlyWhenThereIsLocation() throws {
        #expect(!(try plan(info(.heic), to: .jpeg)).notes.contains(.locationRemoved))
        #expect(try plan(info(.heic, gps: true), to: .jpeg).notes.contains(.locationRemoved))
        #expect(!(try plan(info(.heic, gps: true), to: .jpeg, metadata: .keepAll)).notes.contains(.locationRemoved))
    }

    // MARK: Quality and limits

    @Test func customQualityIsClamped() {
        #expect(QualityPreference.custom(1.7).lossyValue == 1)
        #expect(QualityPreference.custom(-2).lossyValue == 0)
        #expect(QualityPreference.custom(0.8).lossyValue == 0.8)
    }

    @Test func refusesUnwritableTargets() {
        #expect(throws: PlanError.unsupportedTarget(.webp)) {
            try Planner.plan(info(.png), ConvertRequest(target: .webp), writable: [.png, .jpeg])
        }
    }

    @Test func webpIsLosslessAtMaximumAndLossyBelow() throws {
        let lossless = try plan(info(.png, alpha: true), to: .webp)
        #expect(lossless.verdict == .lossless)
        #expect(lossless.lossyQuality == nil)

        let lossy = try Planner.plan(info(.png), ConvertRequest(target: .webp, quality: .custom(0.8)), writable: Self.allWritable)
        #expect(lossy.verdict == .lossy)
        #expect(lossy.lossyQuality == 0.8)
        #expect(lossy.notes.first == .lossyEncode(.webp, quality: 0.8))
    }

    @Test func webpRotatesPixelsAndConvertsNonRGB() throws {
        var source = info(.jpeg, size: 400)
        source.orientation = 6
        source.colorModel = "CMYK"
        let result = try plan(source, to: .webp)
        #expect(result.appliesOrientation)
        #expect(result.notes.contains(.colourModelConverted(from: "CMYK")))
        #expect(result.verdict == .lossy)
    }

    @Test func refusesUnknownSources() {
        var source = info(.png)
        source.format = nil
        #expect(throws: PlanError.self) { try plan(source, to: .png) }
    }

    @Test func refusesGiganticImages() {
        #expect(throws: PlanError.tooLarge(megapixels: 5_000)) {
            try plan(info(.png, size: 100_000), to: .jpeg)
        }
    }

    @Test("A lossless verdict never carries a loss note", arguments: [ImageFormat.jpeg, .png, .heic, .avif, .tiff, .gif])
    func verdictMatchesNotes(_ source: ImageFormat) throws {
        for target in Self.allWritable {
            for variant in [info(source), info(source, depth: 16, alpha: true, gps: true), info(source, hdr: true, frames: 3)] {
                let result = try plan(variant, to: target)
                #expect((result.verdict == .lossy) == result.notes.contains(where: \.isLoss), "\(source)→\(target)")
            }
        }
    }
}
