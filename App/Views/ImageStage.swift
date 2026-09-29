import ImageEngine
import MediaModel
import SwiftUI

/// The preview area. While cropping it shows the whole (rotated) image with
/// an editable crop box; otherwise it shows exactly what will be exported.
struct ImageStage: View {
    @Bindable var document: ImageDocument
    let isCropping: Bool

    var body: some View {
        GeometryReader { proxy in
            let available = CGSize(width: max(proxy.size.width - 24, 1), height: max(proxy.size.height - 24, 1))
            if let preview = document.preview, let display = document.displaySize {
                Group {
                    if isCropping {
                        croppingStage(preview, display: display, available: available)
                    } else {
                        resultStage(preview, display: display, available: available)
                    }
                }
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
    }

    private func croppingStage(_ preview: PreviewImage, display: PixelSize, available: CGSize) -> some View {
        let scale = min(available.width / CGFloat(display.width), available.height / CGFloat(display.height))
        let frame = CGSize(width: CGFloat(display.width) * scale, height: CGFloat(display.height) * scale)
        return OrientedImage(image: preview, orientation: document.geometry.orientation, size: frame)
            .overlay {
                CropOverlay(document: document, display: display, scale: scale)
            }
            .frame(width: frame.width, height: frame.height)
            .onAppear { document.prepareLoupe() }
            .onChange(of: document.geometry.orientation) { document.prepareLoupe() }
    }

    private func resultStage(_ preview: PreviewImage, display: PixelSize, available: CGSize) -> some View {
        let crop = document.effectiveCrop ?? PixelRect(x: 0, y: 0, width: display.width, height: display.height)
        let scale = min(available.width / CGFloat(crop.width), available.height / CGFloat(crop.height))
        let full = CGSize(width: CGFloat(display.width) * scale, height: CGFloat(display.height) * scale)
        return OrientedImage(image: preview, orientation: document.geometry.orientation, size: full)
            .offset(x: -CGFloat(crop.x) * scale, y: -CGFloat(crop.y) * scale)
            .frame(width: CGFloat(crop.width) * scale, height: CGFloat(crop.height) * scale, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }
}

/// The upright preview with the user's rotate/flip applied, filling `size`.
struct OrientedImage: View {
    let image: PreviewImage
    let orientation: Orientation
    let size: CGSize

    var body: some View {
        let inner = orientation.swapsAxes ? CGSize(width: size.height, height: size.width) : size
        Image(decorative: image.cgImage, scale: 1)
            .resizable()
            .interpolation(.high)
            .allowedDynamicRange(image.isHDR ? .high : .standard)
            .frame(width: inner.width, height: inner.height)
            // Orientation is "flip, then rotate clockwise": innermost first.
            .scaleEffect(x: orientation.flipped ? -1 : 1, y: 1)
            .rotationEffect(.degrees(Double(orientation.turns) * 90))
            .frame(width: size.width, height: size.height)
    }
}

// MARK: - Crop overlay

private struct CropOverlay: View {
    @Bindable var document: ImageDocument
    let display: PixelSize
    let scale: CGFloat

    /// The rect while dragging; the document holds the committed one.
    @State private var draft: PixelRect?
    @State private var dragStart: PixelRect?

    private var full: PixelRect { PixelRect(x: 0, y: 0, width: display.width, height: display.height) }
    private var shown: PixelRect { draft ?? document.effectiveCrop ?? full }

    var body: some View {
        let box = viewRect(shown)
        ZStack(alignment: .topLeading) {
            // Dim everything outside the crop.
            Path { path in
                path.addRect(CGRect(x: 0, y: 0, width: CGFloat(display.width) * scale, height: CGFloat(display.height) * scale))
                path.addRect(box)
            }
            .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            ThirdsGrid()
                .stroke(.white.opacity(draft == nil ? 0.25 : 0.5), lineWidth: 0.5)
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
                .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(.white, lineWidth: 1.5)
                .background(Color.white.opacity(0.001))
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
                .gesture(drag(.move))

            ForEach(CropHandle.edges.filter { document.cropAspect.ratio(for: display) == nil || $0.isCorner }, id: \.self) { handle in
                HandleView(isCorner: handle.isCorner)
                    .position(handle.point(in: box))
                    .gesture(drag(handle))
            }
        }
        .frame(width: CGFloat(display.width) * scale, height: CGFloat(display.height) * scale, alignment: .topLeading)
    }

    private func viewRect(_ rect: PixelRect) -> CGRect {
        CGRect(x: CGFloat(rect.x) * scale, y: CGFloat(rect.y) * scale,
               width: CGFloat(rect.width) * scale, height: CGFloat(rect.height) * scale)
    }

    private func drag(_ handle: CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? shown
                if dragStart == nil { dragStart = start }
                let dx = Int((value.translation.width / scale).rounded())
                let dy = Int((value.translation.height / scale).rounded())
                let rect = CropMath.adjust(start, handle: handle, dx: dx, dy: dy, in: display,
                                           ratio: document.cropAspect.ratio(for: display))
                draft = rect
                if handle != .move { document.cropDrag = CropDrag(handle: handle, rect: rect) }
            }
            .onEnded { _ in
                if let draft { document.geometry.crop = draft == full ? nil : draft }
                draft = nil
                dragStart = nil
                document.cropDrag = nil
            }
    }
}

extension CropHandle {
    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .top: CGPoint(x: r.midX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        case .move: CGPoint(x: r.midX, y: r.midY)
        }
    }
}

private struct HandleView: View {
    let isCorner: Bool

    var body: some View {
        Group {
            if isCorner {
                Circle().fill(.white).frame(width: 14, height: 14)
            } else {
                Capsule().fill(.white).frame(width: 22, height: 6)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 2)
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
    }
}

private struct ThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                let y = rect.minY + rect.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
    }
}
