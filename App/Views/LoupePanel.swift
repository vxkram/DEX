import MediaModel
import SwiftUI

/// Shown in place of the Crop panel while a corner or edge is dragged: the
/// exact pixels around that point, magnified, with the crop line on its
/// real pixel boundary.
struct LoupePanel: View {
    let document: ImageDocument
    let drag: CropDrag

    /// Pixels across the loupe (odd, so the point sits in the middle).
    private let span = 21

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Pixel view", systemImage: "square.grid.3x3")
                .font(.headline)

            GeometryReader { proxy in
                let side = proxy.size.width
                LoupeCanvas(
                    loupe: document.loupeImage,
                    display: document.displaySize ?? PixelSize(width: 1, height: 1),
                    crop: drag.rect,
                    center: point,
                    span: span,
                    side: side
                )
            }
            .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "X \(point.x)   Y \(point.y)")
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                Text(verbatim: "Crop \(drag.rect.width) × \(drag.rect.height) at (\(drag.rect.x), \(drag.rect.y))")
                    .font(.technical)
                    .foregroundStyle(.secondary)
                Text(verbatim: "\(span) × \(span) pixels, one square per pixel")
                    .font(.technicalSmall)
                    .foregroundStyle(.secondary)
                if document.loupeImage == nil {
                    Text("Loading full-resolution pixels…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text("Release to set the crop.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.panelCorner, style: .continuous))
    }

    /// The pixel position of the dragged corner or edge, in display space.
    private var point: (x: Int, y: Int) {
        let r = drag.rect
        return switch drag.handle {
        case .topLeft: (r.x, r.y)
        case .top: (r.x + r.width / 2, r.y)
        case .topRight: (r.maxX, r.y)
        case .right: (r.maxX, r.y + r.height / 2)
        case .bottomRight: (r.maxX, r.maxY)
        case .bottom: (r.x + r.width / 2, r.maxY)
        case .bottomLeft: (r.x, r.maxY)
        case .left, .move: (r.x, r.y + r.height / 2)
        }
    }
}

private struct LoupeCanvas: View {
    let loupe: LoupeImage?
    let display: PixelSize
    let crop: PixelRect
    let center: (x: Int, y: Int)
    let span: Int
    let side: CGFloat

    var body: some View {
        let cell = side / CGFloat(span)
        // Region of display pixels shown, with the point in the middle.
        let region = PixelRect(x: center.x - span / 2, y: center.y - span / 2, width: span, height: span)

        ZStack(alignment: .topLeading) {
            Checkerboard(cell: cell / 2)

            if let loupe, let visible = region.clamped(to: display) {
                let scale = Double(loupe.image.cgImage.width) / Double(display.width)
                let sample = CGRect(
                    x: Double(visible.x) * scale, y: Double(visible.y) * scale,
                    width: Double(visible.width) * scale, height: Double(visible.height) * scale
                ).integral
                if let pixels = loupe.image.cgImage.cropping(to: sample) {
                    Image(decorative: pixels, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: CGFloat(visible.width) * cell, height: CGFloat(visible.height) * cell)
                        .offset(x: CGFloat(visible.x - region.x) * cell, y: CGFloat(visible.y - region.y) * cell)
                }
            }

            // Everything outside the crop is dimmed: those pixels are cut away.
            let box = CGRect(
                x: CGFloat(crop.x - region.x) * cell, y: CGFloat(crop.y - region.y) * cell,
                width: CGFloat(crop.width) * cell, height: CGFloat(crop.height) * cell
            )
            Path { path in
                path.addRect(CGRect(x: 0, y: 0, width: side, height: side))
                path.addRect(box)
            }
            .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))

            PixelGrid(cell: cell, count: span)
                .stroke(.white.opacity(0.16), lineWidth: 0.5)

            Rectangle()
                .path(in: box)
                .stroke(Theme.ember, lineWidth: 2)
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}

/// Light grey / white checkerboard for "outside the image".
private struct Checkerboard: View {
    let cell: CGFloat

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.92)))
            let columns = Int(size.width / cell) + 1
            let rows = Int(size.height / cell) + 1
            var squares = Path()
            for row in 0..<rows {
                for column in 0..<columns where (row + column) % 2 == 0 {
                    squares.addRect(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                }
            }
            context.fill(squares, with: .color(Color(white: 0.82)))
        }
    }
}

private struct PixelGrid: Shape {
    let cell: CGFloat
    let count: Int

    func path(in rect: CGRect) -> Path {
        Path { path in
            for i in 1..<count {
                let offset = CGFloat(i) * cell
                path.move(to: CGPoint(x: offset, y: 0))
                path.addLine(to: CGPoint(x: offset, y: rect.height))
                path.move(to: CGPoint(x: 0, y: offset))
                path.addLine(to: CGPoint(x: rect.width, y: offset))
            }
        }
    }
}
