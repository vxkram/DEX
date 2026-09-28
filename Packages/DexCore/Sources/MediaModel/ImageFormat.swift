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

    /// Whether the codec can store pixels without loss.
    public var supportsLossless: Bool {
        switch self {
        case .png, .tiff, .webp, .gif: true
        case .jpeg, .heic, .heif, .avif: false
        }
    }

    public var supportsAlpha: Bool {
        switch self {
        case .jpeg: false
        default: true
        }
    }

    public var supportsAnimation: Bool {
        switch self {
        case .gif, .webp, .heic, .avif: true
        default: false
        }
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
