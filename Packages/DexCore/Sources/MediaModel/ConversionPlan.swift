public enum MetadataPolicy: String, Codable, Sendable, CaseIterable {
    case keepAll
    /// The default: keep camera, copyright and colour data, drop GPS.
    case removeLocation
    /// Drop all metadata except orientation. The colour profile is kept
    /// because it is part of the pixels' meaning, not metadata.
    case removeAll
}

public enum QualityPreference: Codable, Sendable, Equatable {
    /// The highest quality that still makes sense for the codec.
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

    public init(target: ImageFormat, quality: QualityPreference = .maximum, metadata: MetadataPolicy = .removeLocation) {
        self.target = target
        self.quality = quality
        self.metadata = metadata
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
    case metadataEditRequiresReencode(ImageFormat)
    // Information
    case noAdditionalLoss
    case orientationApplied
    case locationRemoved
    case allMetadataRemoved

    public var isLoss: Bool {
        switch self {
        case .noAdditionalLoss, .orientationApplied, .locationRemoved, .allMetadataRemoved: false
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
        case .metadataEditRequiresReencode(let format):
            "\(format.displayName) metadata can't be edited without re-encoding the image"
        case .noAdditionalLoss:
            "No additional loss. The file will likely be larger"
        case .orientationApplied:
            "Rotation will be applied to the pixels, because this format can't store orientation"
        case .locationRemoved:
            "Location data will be removed"
        case .allMetadataRemoved:
            "All metadata except orientation and the camera's HDR data will be removed"
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
    /// Rotate/flip the pixels upright instead of storing an orientation tag.
    public var appliesOrientation: Bool
    /// Output geometry as stored. Checked after writing.
    public var expectedWidth: Int
    public var expectedHeight: Int
    public var expectedFrameCount: Int
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
