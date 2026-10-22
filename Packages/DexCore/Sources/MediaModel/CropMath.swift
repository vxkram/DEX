/// Crop-box editing maths, independent of any UI.
public enum CropHandle: CaseIterable, Sendable {
    case move, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// The eight draggable handles around the box.
    public static let edges: [CropHandle] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]

    public var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
}

public enum CropMath {
    public static let minimumSide = 16

    /// Moves or resizes `start` by a drag, keeping it inside the image and,
    /// when `ratio` (width / height) is set, at that aspect ratio.
    public static func adjust(_ start: PixelRect, handle: CropHandle, dx: Int, dy: Int, in size: PixelSize, ratio: Double?) -> PixelRect {
        if handle == .move {
            let x = min(max(start.x + dx, 0), size.width - start.width)
            let y = min(max(start.y + dy, 0), size.height - start.height)
            return PixelRect(x: x, y: y, width: start.width, height: start.height)
        }
        var left = start.x, top = start.y, right = start.maxX, bottom = start.maxY
        switch handle {
        case .topLeft: left += dx; top += dy
        case .top: top += dy
        case .topRight: right += dx; top += dy
        case .right: right += dx
        case .bottomRight: right += dx; bottom += dy
        case .bottom: bottom += dy
        case .bottomLeft: left += dx; bottom += dy
        case .left: left += dx
        case .move: break
        }
        left = min(max(left, 0), right - minimumSide)
        top = min(max(top, 0), bottom - minimumSide)
        right = max(min(right, size.width), left + minimumSide)
        bottom = max(min(bottom, size.height), top + minimumSide)

        if let ratio {
            // Corner drags only: derive height from width, anchored at the
            // opposite corner, shrinking both if that would leave the image.
            let anchorsTop = handle == .bottomLeft || handle == .bottomRight
            let anchorsLeft = handle == .topRight || handle == .bottomRight
            var width = right - left
            var height = Int((Double(width) / ratio).rounded())
            let room = anchorsTop ? size.height - top : bottom
            if height > room {
                height = room
                width = Int((Double(height) * ratio).rounded())
            }
            if anchorsLeft { right = left + width } else { left = right - width }
            if anchorsTop { bottom = top + height } else { top = bottom - height }
        }
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The largest rect of `ratio` centred in the image.
    public static func centred(ratio: Double, in size: PixelSize) -> PixelRect {
        var width = size.width
        var height = Int((Double(width) / ratio).rounded())
        if height > size.height {
            height = size.height
            width = Int((Double(height) * ratio).rounded())
        }
        return PixelRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}

/// Aspect-ratio presets for the crop tool.
public enum CropAspect: String, CaseIterable, Identifiable, Sendable {
    case free, square, threeFour, fourThree, sixteenNine, nineSixteen

    public var id: Self { self }

    public var title: String {
        switch self {
        case .free: "Free"
        case .square: "1:1"
        case .threeFour: "3:4"
        case .fourThree: "4:3"
        case .sixteenNine: "16:9"
        case .nineSixteen: "9:16"
        }
    }

    /// Width / height, or nil for a free crop.
    public var ratio: Double? {
        switch self {
        case .free: nil
        case .square: 1
        case .threeFour: 3.0 / 4
        case .fourThree: 4.0 / 3
        case .sixteenNine: 16.0 / 9
        case .nineSixteen: 9.0 / 16
        }
    }
}
