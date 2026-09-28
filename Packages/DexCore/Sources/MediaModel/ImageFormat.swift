/// Image formats DEX knows about.
///
/// Identified by Uniform Type Identifier strings rather than `UTType` so this
/// module depends on Foundation only.
public enum ImageFormat: String, Codable, Sendable, CaseIterable {
    case jpeg
    case png
    case heic
    case heif
    case webp
    case avif
    case tiff
    case gif

    public var typeIdentifier: String {
        switch self {
        case .jpeg: "public.jpeg"
        case .png: "public.png"
        case .heic: "public.heic"
        case .heif: "public.heif"
        case .webp: "org.webmproject.webp"
        case .avif: "public.avif"
        case .tiff: "public.tiff"
        case .gif: "com.compuserve.gif"
        }
    }

    public var preferredFileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .tiff: "tiff"
        default: rawValue
        }
    }

    /// Whether the codec can store arbitrary pixels without loss.
    /// GIF is excluded: it is limited to a 256-colour palette.
    public var supportsLossless: Bool {
        switch self {
        case .png, .tiff, .webp: true
        case .jpeg, .heic, .heif, .avif, .gif: false
        }
    }

    public var supportsAlpha: Bool {
        switch self {
        case .jpeg: false
        default: true
        }
    }

    /// Multi-frame output as DEX implements it today.
    public var supportsAnimation: Bool {
        self == .gif
    }

    /// Highest bits per component the encoder keeps (measured on macOS 27).
    public var maxBitsPerComponent: Int {
        switch self {
        case .jpeg, .gif, .webp: 8
        case .heic, .heif, .avif: 10
        case .png: 16
        case .tiff: 32
        }
    }

    /// Whether ImageIO can rewrite metadata without touching the coded image
    /// data (`CGImageDestinationCopyImageSource`). Measured on macOS 27:
    /// AVIF and GIF report "not supported for lossless metadata modification",
    /// and PNG keeps GPS stored in its eXIf chunk.
    public var supportsLosslessMetadataEdit: Bool {
        switch self {
        case .jpeg, .tiff, .heic: true
        case .png, .gif, .heif, .avif, .webp: false
        }
    }

    /// Whether decoding and re-encoding a file of this format as the same
    /// format reproduces its pixels exactly. GIF qualifies because its
    /// existing palette is kept.
    public var reencodesLosslessly: Bool {
        supportsLossless || self == .gif
    }

    /// Whether an HDR gain map can be stored alongside the image, verified
    /// by decoding the output to HDR on macOS 27. PNG, TIFF and GIF have no
    /// standard place for one.
    public var supportsGainMap: Bool {
        switch self {
        case .jpeg, .heic, .avif: true
        case .png, .tiff, .gif, .heif, .webp: false
        }
    }

    /// Whether the encoder keeps an EXIF-style orientation tag. ImageIO's
    /// AVIF encoder silently drops it (macOS 27), so rotation must be
    /// applied to the pixels instead.
    public var supportsOrientationTag: Bool {
        self != .avif
    }

    public init?(typeIdentifier: String) {
        // Sequence variants (e.g. animated HEIC) map onto their still format.
        let aliases: [String: ImageFormat] = [
            "public.heics": .heic,
            "public.avis": .avif,
            "public.jpg": .jpeg,
        ]
        if let alias = aliases[typeIdentifier] {
            self = alias
            return
        }
        guard let match = ImageFormat.allCases.first(where: { $0.typeIdentifier == typeIdentifier }) else {
            return nil
        }
        self = match
    }
}
