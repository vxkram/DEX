import Foundation

/// An extra image taking part in a composition, with what inspection
/// found out about it (formats don't matter: every input is decoded).
public struct ComposedImage: Codable, Sendable, Equatable, Hashable {
    public var url: URL
    public var info: MediaInfo

    public init(url: URL, info: MediaInfo) {
        self.url = url
        self.info = info
    }

    public static func == (a: ComposedImage, b: ComposedImage) -> Bool { a.url == b.url }
    public func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// One image placed on top of the base, in canvas pixels.
public struct OverlayLayer: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var image: ComposedImage
    /// Centre of the layer on the canvas.
    public var centerX: Double
    public var centerY: Double
    /// Drawn width; height follows the image's aspect ratio.
    public var width: Double
    /// Clockwise degrees.
    public var rotation: Double
    /// 0 (invisible) to 1 (opaque).
    public var opacity: Double

    public init(id: UUID = UUID(), image: ComposedImage, centerX: Double, centerY: Double,
                width: Double, rotation: Double = 0, opacity: Double = 1) {
        self.id = id
        self.image = image
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.rotation = rotation
        self.opacity = opacity
    }

    public var aspectRatio: Double {
        let size = image.info.displaySize
        return Double(size.width) / Double(max(size.height, 1))
    }

    public var height: Double { width / aspectRatio }

    /// Whether the layer is drawn at a size other than its own pixels.
    public var isResampled: Bool {
        Int(width.rounded()) != image.info.displaySize.width || rotation.truncatingRemainder(dividingBy: 90) != 0
    }

    /// A layer that fits inside `canvas` at up to `fraction` of its width,
    /// centred, never enlarged beyond its own pixels.
    public static func placed(_ image: ComposedImage, on canvas: PixelSize, fraction: Double = 0.4) -> OverlayLayer {
        let native = Double(image.info.displaySize.width)
        let aspect = Double(image.info.displaySize.width) / Double(max(image.info.displaySize.height, 1))
        let fitWidth = min(Double(canvas.width) * fraction, Double(canvas.height) * fraction * aspect)
        return OverlayLayer(image: image, centerX: Double(canvas.width) / 2, centerY: Double(canvas.height) / 2,
                            width: min(native, fitWidth).rounded())
    }
}

/// Several images joined into one picture.
public struct Arrangement: Codable, Sendable, Equatable {
    public enum Layout: Codable, Sendable, Equatable {
        case horizontal
        case vertical
        case grid(columns: Int)
    }

    public enum Sizing: String, Codable, Sendable, CaseIterable {
        /// Scale down so heights (rows) or widths (columns) match the
        /// smallest image. Never enlarges.
        case matchSmallest
        /// Keep every image at its own pixel size.
        case original
    }

    public enum Alignment: String, Codable, Sendable, CaseIterable {
        case start, center, end
    }

    public enum Background: Codable, Sendable, Equatable {
        case transparent
        /// sRGB components 0...1.
        case color(red: Double, green: Double, blue: Double)

        public static let white = Background.color(red: 1, green: 1, blue: 1)
        public static let black = Background.color(red: 0, green: 0, blue: 0)
    }

    public var layout: Layout
    /// The images after the base, in order.
    public var images: [ComposedImage]
    public var spacing: Int
    public var sizing: Sizing
    public var alignment: Alignment
    public var background: Background

    public init(layout: Layout, images: [ComposedImage], spacing: Int = 0, sizing: Sizing = .matchSmallest,
                alignment: Alignment = .center, background: Background = .white) {
        self.layout = layout
        self.images = images
        self.spacing = spacing
        self.sizing = sizing
        self.alignment = alignment
        self.background = background
    }
}

public enum Composition: Codable, Sendable, Equatable {
    /// Images placed over the base.
    case layers([OverlayLayer])
    /// The base and more images joined into one picture.
    case arrangement(Arrangement)

    public var extraImages: [ComposedImage] {
        switch self {
        case .layers(let layers): layers.map(\.image)
        case .arrangement(let arrangement): arrangement.images
        }
    }

    public var isEmpty: Bool { extraImages.isEmpty }
}

/// Where each image goes in an arrangement. Pure, so the planner, the
/// engine and the preview always agree.
public enum ArrangementLayout {
    public struct Result: Equatable, Sendable {
        public var canvas: PixelSize
        /// One frame per input, in canvas pixels.
        public var frames: [PixelRect]

        public init(canvas: PixelSize, frames: [PixelRect]) {
            self.canvas = canvas
            self.frames = frames
        }
    }

    public static func layout(_ sizes: [PixelSize], _ arrangement: Arrangement) -> Result {
        guard !sizes.isEmpty else { return Result(canvas: PixelSize(width: 1, height: 1), frames: []) }
        switch arrangement.layout {
        case .horizontal:
            return rows([sizes], arrangement)
        case .vertical:
            let transposed = rows([sizes.map(\.transposed)], arrangement)
            return Result(
                canvas: transposed.canvas.transposed,
                frames: transposed.frames.map { PixelRect(x: $0.y, y: $0.x, width: $0.height, height: $0.width) }
            )
        case .grid(let columns):
            let perRow = max(columns, 1)
            let grouped = stride(from: 0, to: sizes.count, by: perRow).map { Array(sizes[$0..<min($0 + perRow, sizes.count)]) }
            return rows(grouped, arrangement)
        }
    }

    /// Rows laid out left to right, rows top to bottom.
    private static func rows(_ rows: [[PixelSize]], _ arrangement: Arrangement) -> Result {
        let spacing = max(arrangement.spacing, 0)
        // With matchSmallest every image takes the smallest height.
        let commonHeight = rows.flatMap { $0 }.map(\.height).min() ?? 1
        var laidOut: [(sizes: [PixelSize], height: Int, width: Int)] = []
        for row in rows {
            let sizes = row.map { size -> PixelSize in
                guard arrangement.sizing == .matchSmallest, size.height > commonHeight else { return size }
                let width = max(Int((Double(size.width) * Double(commonHeight) / Double(size.height)).rounded()), 1)
                return PixelSize(width: width, height: commonHeight)
            }
            let width = sizes.map(\.width).reduce(0, +) + spacing * (sizes.count - 1)
            laidOut.append((sizes, sizes.map(\.height).max() ?? 1, width))
        }
        let canvasWidth = laidOut.map(\.width).max() ?? 1
        var frames: [PixelRect] = []
        var y = 0
        for row in laidOut {
            var x = offset(canvasWidth - row.width, arrangement.alignment)
            for size in row.sizes {
                frames.append(PixelRect(x: x, y: y + offset(row.height - size.height, arrangement.alignment),
                                        width: size.width, height: size.height))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
        return Result(canvas: PixelSize(width: canvasWidth, height: max(y - spacing, 1)), frames: frames)
    }

    private static func offset(_ room: Int, _ alignment: Arrangement.Alignment) -> Int {
        switch alignment {
        case .start: 0
        case .center: room / 2
        case .end: room
        }
    }
}
