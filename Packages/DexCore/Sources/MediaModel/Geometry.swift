/// A rectangle in whole pixels, origin at the top-left.
public struct PixelRect: Codable, Sendable, Equatable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var size: PixelSize { PixelSize(width: width, height: height) }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }

    /// Intersection with an image of `size`, or nil if nothing is left.
    public func clamped(to size: PixelSize) -> PixelRect? {
        let left = max(0, x), top = max(0, y)
        let right = min(size.width, maxX), bottom = min(size.height, maxY)
        guard right > left, bottom > top else { return nil }
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    public var description: String { "\(width)×\(height) at (\(x), \(y))" }
}

public struct PixelSize: Codable, Sendable, Equatable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var transposed: PixelSize { PixelSize(width: height, height: width) }
    public var description: String { "\(width) × \(height)" }
}

/// One of the eight EXIF orientations, as "flip horizontally (optional),
/// then rotate clockwise by `turns` quarter turns", mapping stored pixels
/// to what is displayed.
public struct Orientation: Codable, Sendable, Equatable {
    public var flipped: Bool
    /// Clockwise quarter turns, 0...3.
    public var turns: Int

    public init(flipped: Bool = false, turns: Int = 0) {
        self.flipped = flipped
        self.turns = ((turns % 4) + 4) % 4
    }

    public static let identity = Orientation()

    public init(exif: Int) {
        switch exif {
        case 2: self.init(flipped: true, turns: 0)
        case 3: self.init(turns: 2)
        case 4: self.init(flipped: true, turns: 2)
        case 5: self.init(flipped: true, turns: 3)
        case 6: self.init(turns: 1)
        case 7: self.init(flipped: true, turns: 1)
        case 8: self.init(turns: 3)
        default: self.init()
        }
    }

    public var exif: Int {
        switch (flipped, turns) {
        case (false, 0): 1
        case (true, 0): 2
        case (false, 2): 3
        case (true, 2): 4
        case (true, 3): 5
        case (false, 1): 6
        case (true, 1): 7
        default: 8  // (false, 3)
        }
    }

    public var isIdentity: Bool { !flipped && turns == 0 }
    public var swapsAxes: Bool { turns % 2 == 1 }

    /// `self` first, then `next`. Uses F·R = R⁻¹·F.
    public func followed(by next: Orientation) -> Orientation {
        Orientation(flipped: flipped != next.flipped, turns: next.turns + (next.flipped ? -turns : turns))
    }

    public var inverse: Orientation {
        Orientation(flipped: flipped, turns: flipped ? turns : -turns)
    }

    public func apply(to size: PixelSize) -> PixelSize {
        swapsAxes ? size.transposed : size
    }

    /// Maps a rectangle in an image of `size` (before this orientation) to
    /// where it lands after it.
    public func apply(to rect: PixelRect, in size: PixelSize) -> PixelRect {
        var r = rect
        var s = size
        if flipped {
            r = PixelRect(x: s.width - r.maxX, y: r.y, width: r.width, height: r.height)
        }
        for _ in 0..<turns {
            // 90° clockwise: (x, y) → (H − y, x)
            r = PixelRect(x: s.height - r.maxY, y: r.x, width: r.height, height: r.width)
            s = s.transposed
        }
        return r
    }
}

/// Fit: the whole picture on a canvas of an aspect ratio, the space
/// around it filled with a background. The picture's own pixels are never
/// resampled; only pixels are added around them.
public struct Framing: Codable, Sendable, Equatable {
    public enum Background: Codable, Sendable, Equatable {
        /// sRGB components 0...1.
        case color(red: Double, green: Double, blue: Double)
        case transparent
        /// A blurred, slightly darkened copy of the picture, filling the canvas.
        case blur

        public static let white = Background.color(red: 1, green: 1, blue: 1)
        public static let black = Background.color(red: 0, green: 0, blue: 0)
    }

    /// Width / height of the canvas.
    public var ratio: Double
    public var background: Background

    public init(ratio: Double, background: Background = .white) {
        self.ratio = ratio
        self.background = background
    }

    /// The smallest canvas of `ratio` that holds the whole image at its own
    /// size, and where the image sits on it (centred). Shared by the
    /// planner, the engine and the preview so they always agree.
    public func canvas(for size: PixelSize) -> (canvas: PixelSize, imageRect: PixelRect) {
        let canvas = Double(size.width) / Double(max(size.height, 1)) > ratio
            ? PixelSize(width: size.width, height: max(Int((Double(size.width) / ratio).rounded()), size.height))
            : PixelSize(width: max(Int((Double(size.height) * ratio).rounded()), size.width), height: size.height)
        let rect = PixelRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                             width: size.width, height: size.height)
        return (canvas, rect)
    }
}

/// Edits applied in display space, in this order: rotate/flip, crop, frame
/// (Fit), resize.
public struct Geometry: Codable, Sendable, Equatable {
    /// Rotation and flip on top of the file's own orientation.
    public var orientation: Orientation
    /// Crop in the rotated/flipped display space.
    public var crop: PixelRect?
    /// Crop exactly, even when a lossless JPEG crop would need to snap to
    /// block boundaries. Forces a re-encode for JPEG.
    public var exactCrop: Bool
    /// Fit the (cropped) picture onto a canvas of another aspect ratio.
    public var frame: Framing?
    /// Output size after cropping and framing.
    public var resize: PixelSize?
    /// Animations saved as animations: the frames kept (0-based, inclusive).
    public var frameRange: ClosedRange<Int>?
    /// Animations saved as a still image: the frame to keep (0-based).
    public var stillFrame: Int?

    public init(orientation: Orientation = .identity, crop: PixelRect? = nil, exactCrop: Bool = false,
                frame: Framing? = nil, resize: PixelSize? = nil, frameRange: ClosedRange<Int>? = nil, stillFrame: Int? = nil) {
        self.orientation = orientation
        self.crop = crop
        self.exactCrop = exactCrop
        self.frame = frame
        self.resize = resize
        self.frameRange = frameRange
        self.stillFrame = stillFrame
    }

    public static let none = Geometry()

    public var isIdentity: Bool {
        orientation.isIdentity && crop == nil && frame == nil && resize == nil && frameRange == nil && stillFrame == nil
    }

    public mutating func rotateClockwise() {
        orientation = orientation.followed(by: Orientation(turns: 1))
        crop = nil
    }

    public mutating func rotateCounterclockwise() {
        orientation = orientation.followed(by: Orientation(turns: 3))
        crop = nil
    }

    /// Mirrors what is currently displayed left to right.
    public mutating func flipHorizontally() {
        orientation = orientation.followed(by: Orientation(flipped: true))
        crop = nil
    }

    public mutating func flipVertically() {
        orientation = orientation.followed(by: Orientation(flipped: true, turns: 2))
        crop = nil
    }
}
