public enum MetadataPolicy: String, Codable, Sendable, CaseIterable {
    case keepAll
    /// The default: keep camera, copyright and colour data, drop GPS.
    case removeLocation
    /// Drop all metadata except orientation. The colour profile is kept
    /// because it is part of the pixels' meaning, not metadata.
    case removeAll
}

public enum QualityPreference: Codable, Sendable, Equatable {
    /// The highest quality that still makes sense for the codec: lossless
    /// for WebP, 0.95 for JPEG, HEIC and AVIF.
    case maximum
    /// Lossy encoder quality, 0...1.
    case custom(Double)

    public static let maximumLossyQuality = 0.95

    public var lossyValue: Double {
        switch self {
        case .maximum: Self.maximumLossyQuality
        case .custom(let value): min(max(value, 0), 1)
        }
    }
}

public struct ConvertRequest: Codable, Sendable, Equatable {
    public var target: ImageFormat
    public var quality: QualityPreference
    public var metadata: MetadataPolicy
    public var geometry: Geometry
    /// Lossless compression: repack the data as small as possible without
    /// changing a pixel (JPEG Huffman optimisation, PNG/TIFF re-encode).
    public var optimize: Bool
    /// Extra images layered on top of, or arranged next to, the source.
    public var composition: Composition?

    public init(
        target: ImageFormat,
        quality: QualityPreference = .maximum,
        metadata: MetadataPolicy = .removeLocation,
        geometry: Geometry = .none,
        optimize: Bool = false,
        composition: Composition? = nil
    ) {
        self.target = target
        self.quality = quality
        self.metadata = metadata
        self.geometry = geometry
        self.optimize = optimize
        self.composition = composition
    }
}

public enum QualityVerdict: String, Codable, Sendable {
    /// The coded image data is untouched.
    case noReencode
    /// Pixels are decoded and stored again without further loss.
    case lossless
    /// Some information is lost. The plan's notes say exactly what.
    case lossy

    public var label: String {
        switch self {
        case .noReencode: "No re-encode"
        case .lossless: "Lossless"
        case .lossy: "Re-encode (lossy)"
        }
    }
}

public enum ConversionStrategy: String, Codable, Sendable {
    /// Byte-for-byte copy.
    case copyFile
    /// Rewrite metadata around the original coded image data.
    case rewriteMetadata
    /// Crop and/or optimise JPEG coefficients without decoding
    /// (libjpeg-turbo), then rewrite metadata.
    case losslessJPEGTransform
    /// Decode and encode.
    case reencode
}

public enum QualityNote: Codable, Sendable, Equatable, CustomStringConvertible {
    // Losses
    case lossyEncode(ImageFormat, quality: Double)
    case paletteLimited
    case transparencyFlattened
    case animationFirstFrameOnly(frames: Int)
    case bitDepthReduced(from: Int, to: Int)
    case hdrDropped(to: ImageFormat)
    case colourModelConverted(from: String)
    case metadataEditRequiresReencode(ImageFormat)
    case resampled(from: PixelSize, to: PixelSize)
    case hdrNotKeptByLosslessCrop
    case imageResampled(name: String, to: PixelSize)
    case hdrNotKeptInComposite
    case hdrNotKeptByFit
    // Information
    case noAdditionalLoss
    case orientationApplied
    case cropSnapped(to: PixelRect)
    case optimisedLosslessly
    case composited(images: Int)
    case framed(to: PixelSize, background: Framing.Background)
    case locationRemoved
    case allMetadataRemoved

    public var isLoss: Bool {
        switch self {
        case .noAdditionalLoss, .orientationApplied, .cropSnapped, .optimisedLosslessly, .composited, .framed,
             .locationRemoved, .allMetadataRemoved: false
        default: true
        }
    }

    public var description: String {
        switch self {
        case .lossyEncode(let format, let quality):
            "\(format.displayName) encoding at quality \(Int((quality * 100).rounded()))"
        case .paletteLimited:
            "GIF is limited to 256 colours"
        case .transparencyFlattened:
            "Transparency will be flattened onto white"
        case .animationFirstFrameOnly(let frames):
            "Animation will be reduced to its first frame (of \(frames))"
        case .bitDepthReduced(let from, let to):
            "Colour depth reduced from \(from)-bit to \(to)-bit"
        case .hdrDropped(let format):
            "HDR will be dropped: \(format.displayName) can't store a gain map, so bright highlights will look flatter on HDR screens"
        case .colourModelConverted(let model):
            "Colours will be converted from \(model) to sRGB, which can shift them slightly"
        case .metadataEditRequiresReencode(let format):
            "\(format.displayName) metadata can't be edited without re-encoding the image"
        case .noAdditionalLoss:
            "No additional loss. The file will likely be larger"
        case .resampled(let from, let to):
            "Resized from \(from) to \(to): resampling creates new pixels"
        case .hdrNotKeptByLosslessCrop:
            "HDR gain map can't be kept by a lossless JPEG transform yet"
        case .cropSnapped(let rect):
            "Crop adjusted to \(rect.size) so it stays lossless (JPEG crops start on 8/16-pixel blocks)"
        case .imageResampled(let name, let size):
            "\(name) is scaled to \(size) (resampled)"
        case .hdrNotKeptInComposite:
            "HDR can't be kept when combining images, so the result is SDR"
        case .hdrNotKeptByFit:
            "HDR can't be kept when fitting to a new shape, so the result is SDR"
        case .framed(let size, let background):
            "Fitted on a \(size) canvas with \(background.phrase) around it; the photo's own pixels aren't resampled"
        case .composited(let count):
            "Combines \(count + 1) images; formats don't matter, colours are matched"
        case .optimisedLosslessly:
            "Compressed losslessly: the data is repacked, every pixel stays identical"
        case .orientationApplied:
            "Rotation will be applied to the pixels, because this format can't store orientation"
        case .locationRemoved:
            "Location data will be removed"
        case .allMetadataRemoved:
            "All metadata except orientation and the camera's HDR data will be removed"
        }
    }
}

extension Framing.Background {
    var phrase: String {
        switch self {
        case .transparent: "transparency"
        case .blur: "a blurred copy"
        case .color(1, 1, 1): "white"
        case .color(0, 0, 0): "black"
        case .color: "a colour"
        }
    }
}

public struct ConversionPlan: Codable, Sendable, Equatable {
    public var request: ConvertRequest
    public var strategy: ConversionStrategy
    public var verdict: QualityVerdict
    public var notes: [QualityNote]
    /// Encoder quality, only set when a lossy codec is used.
    public var lossyQuality: Double?
    /// A format that would avoid every loss in `notes`, offered to the user
    /// when the verdict is lossy.
    public var losslessAlternative: ImageFormat?
    /// The output carries the source's HDR gain map. Checked after writing.
    public var preservesHDR: Bool
    /// EXIF orientation applied to the pixels (1 = none).
    public var bakedOrientation: Int
    /// Orientation tag the output must carry. Checked after writing.
    public var outputOrientation: Int
    /// Crop in the space the engine works in: stored pixels for
    /// `.losslessJPEGTransform`, pixels after `bakedOrientation` for `.reencode`.
    public var pixelCrop: PixelRect?
    /// Fit after the crop, when it changes the size.
    public var frame: Framing?
    /// Final pixel size after cropping and framing, when resampling.
    public var resize: PixelSize?
    /// The crop as the user will see it, after any lossless snapping.
    public var displayCrop: PixelRect?
    /// Output geometry as stored. Checked after writing.
    public var expectedWidth: Int
    public var expectedHeight: Int
    public var expectedFrameCount: Int

    public var appliesOrientation: Bool { bakedOrientation != 1 }
    /// The displayed size of the result.
    public var outputDisplaySize: PixelSize {
        Orientation(exif: outputOrientation).apply(to: PixelSize(width: expectedWidth, height: expectedHeight))
    }
}

public enum PlanError: Error, Equatable, CustomStringConvertible {
    case unsupportedSource(String)
    case unsupportedTarget(ImageFormat)
    case tooLarge(megapixels: Int)

    public var description: String {
        switch self {
        case .unsupportedSource(let type): "DEX can't convert files of type \(type) yet."
        case .unsupportedTarget(let format): "This Mac can't write \(format.displayName) files yet."
        case .tooLarge(let megapixels): "The image is \(megapixels) megapixels, above the \(Planner.maxMegapixels) MP safety limit."
        }
    }
}

extension ImageFormat {
    public var displayName: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .heif: "HEIF"
        case .webp: "WebP"
        case .avif: "AVIF"
        case .tiff: "TIFF"
        case .gif: "GIF"
        }
    }
}
