import Foundation

/// AI enhancement: a larger, sharper, cleaner picture made by a model. It
/// always invents pixels, so it is always disclosed as a loss of fidelity.
public struct Enhancement: Codable, Sendable, Equatable {
    public enum Style: String, Codable, Sendable, CaseIterable {
        /// Photos, quick; with a noise strength.
        case fast
        /// Photos, the most natural detail; slower.
        case best
        /// Drawings, anime and flat-colour art: crisp lines.
        case anime
    }

    public enum Denoise: String, Codable, Sendable, CaseIterable {
        case low, medium, high
    }

    /// 2 or 4.
    public var scale: Int
    public var style: Style
    /// Only used by `.fast`.
    public var denoise: Denoise
    /// Restore faces with GFPGAN after upscaling.
    public var faces: Bool

    public init(scale: Int = 2, style: Style = .fast, denoise: Denoise = .medium, faces: Bool = false) {
        self.scale = scale == 4 ? 4 : 2
        self.style = style
        self.denoise = denoise
        self.faces = faces
    }

    /// The upscaling model these settings need.
    public var upscaler: EnhanceModel {
        switch style {
        case .best: .best
        case .anime: .anime
        case .fast:
            switch denoise {
            case .low: .fastLow
            case .medium: .fastMedium
            case .high: .fastHigh
            }
        }
    }

    /// Every model these settings need.
    public var models: [EnhanceModel] { faces ? [upscaler, .faces] : [upscaler] }

    public func output(for size: PixelSize) -> PixelSize {
        PixelSize(width: size.width * scale, height: size.height * scale)
    }
}

/// The models DEX can download, pinned to the files of the GitHub release
/// `models-1` (built by scripts/models/build.py). A file that doesn't match
/// its size and SHA-256 is refused.
public enum EnhanceModel: String, Codable, Sendable, CaseIterable, Identifiable {
    case fastLow = "dex-fast-low"
    case fastMedium = "dex-fast-medium"
    case fastHigh = "dex-fast-high"
    case best = "dex-best"
    case anime = "dex-anime"
    case faces = "dex-faces"

    public var id: Self { self }

    public static let releaseBase = "https://github.com/vxkram/DEX/releases/download/models-1/"

    public var downloadURL: URL { URL(string: Self.releaseBase + rawValue + ".mlpackage.zip")! }

    public var title: String {
        switch self {
        case .fastLow: "Fast (low noise removal)"
        case .fastMedium: "Fast"
        case .fastHigh: "Fast (strong noise removal)"
        case .best: "Best"
        case .anime: "Anime"
        case .faces: "Faces"
        }
    }

    /// Download size in bytes.
    public var bytes: Int64 {
        switch self {
        case .fastLow: 2_291_418
        case .fastMedium: 2_291_783
        case .fastHigh: 2_291_697
        case .best: 13_399_063
        case .anime: 3_681_164
        case .faces: 76_310_814
        }
    }

    public var sha256: String {
        switch self {
        case .fastLow: "8dc54d169fa41f36100e3c1bda0a7f72f04b7f8ff7f8b891cf2ed8f22127d5de"
        case .fastMedium: "d669e1fffa0ffe16ff08d7d6904e133e21f9801e45a6cf8ab8a51bda35c5272e"
        case .fastHigh: "25d7c005345893873ff3571c48aeb3476888c08830cde77d2c71d93d1558d832"
        case .best: "ef9132f155be8e7ff5bf7b4b272657221972aeac341a15140c98dde581483d32"
        case .anime: "c8257b195556ca0b174fac7f6b889b8ef3c2eb6e04a1663f70d436625e892640"
        case .faces: "8ed370f5ededb28fcbb3029a4a94ccc177c9fb6ba0543f6b397e0aab12ef2055"
        }
    }

    /// Side of the square image the model takes.
    public var inputSide: Int { self == .faces ? 512 : 256 }

    public var credit: String {
        self == .faces
            ? "GFPGAN v1.4 (Apache-2.0), trained on FFHQ"
            : "Real-ESRGAN (BSD-3-Clause)"
    }
}

/// How an image is cut into overlapping tiles for a 4× model, and which
/// part of each result is kept. Pure, so it can be tested.
public enum EnhanceTiling {
    public struct Tile: Equatable, Sendable {
        /// The model's input: a `side`² window of the source. It can reach
        /// past a small image's edge, where the edge pixels are repeated.
        public var window: PixelRect
        /// The part of the window whose result is kept, in window pixels.
        public var keep: PixelRect
        /// Where the kept part goes in the source (multiply by the scale
        /// for the output).
        public var target: PixelRect
    }

    /// Every tile keeps `overlap` pixels of context on its inner sides, so
    /// the model never sees a cut edge where results meet.
    public static func tiles(for size: PixelSize, side: Int = 256, overlap: Int = 16) -> [Tile] {
        let step = max(side - 2 * overlap, 1)
        func spans(_ length: Int) -> [(window: Int, keep: Int, core: Range<Int>)] {
            stride(from: 0, to: max(length, 1), by: step).map { start in
                let core = start..<min(start + step, length)
                let window = min(max(start - overlap, 0), max(length - side, 0))
                return (window, start - window, core)
            }
        }
        var result: [Tile] = []
        for row in spans(size.height) {
            for column in spans(size.width) {
                result.append(Tile(
                    window: PixelRect(x: column.window, y: row.window, width: side, height: side),
                    keep: PixelRect(x: column.keep, y: row.keep, width: column.core.count, height: row.core.count),
                    target: PixelRect(x: column.core.lowerBound, y: row.core.lowerBound,
                                      width: column.core.count, height: row.core.count)
                ))
            }
        }
        return result
    }
}
