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
                    } else if document.composition != nil {
                        CompositeStage(document: document, available: available)
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

// MARK: - Composite preview

/// A live, approximate preview of the composition from the small
/// previews; the export renders the same layout at full resolution.
private struct CompositeStage: View {
    @Bindable var document: ImageDocument
    let available: CGSize

    var body: some View {
        if let preview = document.preview, let display = document.displaySize, let base = document.croppedSize {
            let crop = document.effectiveCrop ?? PixelRect(x: 0, y: 0, width: display.width, height: display.height)
            let layout = canvasLayout(base: base)
            let scale = min(available.width / CGFloat(layout.canvas.width), available.height / CGFloat(layout.canvas.height))

            ZStack(alignment: .topLeading) {
                backgroundView
                // The (rotated, cropped) base.
                // In "match sizes" arrangements the base itself may be scaled.
                let baseScale = scale * CGFloat(layout.frames[baseIndex].width) / CGFloat(crop.width)
                let baseFrame = layout.frames[baseIndex]
                CroppedBase(preview: preview, orientation: document.geometry.orientation, display: display, crop: crop, scale: baseScale)
                    .frame(width: CGFloat(baseFrame.width) * scale, height: CGFloat(baseFrame.height) * scale)
                    .offset(x: CGFloat(baseFrame.x) * scale, y: CGFloat(baseFrame.y) * scale)

                if document.composeMode == .layers {
                    ForEach(document.layers) { layer in
                        LayerView(document: document, layer: layer, scale: scale, isEditable: document.tool == .compose)
                    }
                } else {
                    ForEach(Array(document.arrangedImages.enumerated()), id: \.element.url) { index, image in
                        let frame = layout.frames[index < baseIndex ? index : index + 1]
                        Group {
                            if let extra = document.extraPreviews[image.url] {
                                Image(decorative: extra.cgImage, scale: 1).resizable().interpolation(.high)
                            } else {
                                Rectangle().fill(.white.opacity(0.1)).overlay(ProgressView())
                            }
                        }
                        .frame(width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale)
                        .offset(x: CGFloat(frame.x) * scale, y: CGFloat(frame.y) * scale)
                    }
                }
            }
            .frame(width: CGFloat(layout.canvas.width) * scale, height: CGFloat(layout.canvas.height) * scale, alignment: .topLeading)
            .clipped()
            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        }
    }

    private var baseIndex: Int {
        document.composeMode == .layers ? 0 : document.arrangement.clampedBasePosition
    }

    private func canvasLayout(base: PixelSize) -> ArrangementLayout.Result {
        if document.composeMode == .layers {
            return ArrangementLayout.Result(canvas: base, frames: [PixelRect(x: 0, y: 0, width: base.width, height: base.height)])
        }
        let arrangement = document.arrangement
        return ArrangementLayout.layout(
            arrangement.ordered(base: base, others: document.arrangedImages.map(\.info.displaySize)), arrangement
        )
    }

    @ViewBuilder private var backgroundView: some View {
        if document.composeMode != .layers {
            switch document.background {
            case .transparent: TransparencyPattern()
            case .color(let r, let g, let b): Color(red: r, green: g, blue: b)
            }
        }
    }
}

/// The base preview with the user's rotate/flip and crop, filling a frame.
private struct CroppedBase: View {
    let preview: PreviewImage
    let orientation: Orientation
    let display: PixelSize
    let crop: PixelRect
    let scale: CGFloat

    var body: some View {
        OrientedImage(image: preview, orientation: orientation,
                      size: CGSize(width: CGFloat(display.width) * scale, height: CGFloat(display.height) * scale))
            .offset(x: -CGFloat(crop.x) * scale, y: -CGFloat(crop.y) * scale)
            .frame(width: CGFloat(crop.width) * scale, height: CGFloat(crop.height) * scale, alignment: .topLeading)
            .clipped()
    }
}

/// One overlay layer: drag to move, drag the corner to resize.
private struct LayerView: View {
    @Bindable var document: ImageDocument
    let layer: OverlayLayer
    let scale: CGFloat
    let isEditable: Bool

    @State private var moveStart: CGPoint?
    @State private var resizeStart: Double?

    var body: some View {
        let isSelected = isEditable && document.selectedLayerID == layer.id
        let size = CGSize(width: layer.width * scale, height: layer.height * scale)
        Group {
            if let preview = document.extraPreviews[layer.image.url] {
                Image(decorative: preview.cgImage, scale: 1).resizable().interpolation(.high)
            } else {
                Rectangle().fill(.white.opacity(0.15))
            }
        }
        .frame(width: size.width, height: size.height)
        .opacity(layer.opacity)
        .overlay {
            if isSelected {
                Rectangle().strokeBorder(Theme.ember, lineWidth: 1.5)
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(.white).frame(width: 14, height: 14)
                            .shadow(color: .black.opacity(0.4), radius: 2)
                            .offset(x: 7, y: 7)
                            .gesture(resize)
                    }
            }
        }
        .rotationEffect(.degrees(layer.rotation))
        .position(x: layer.centerX * scale, y: layer.centerY * scale)
        .gesture(isEditable ? move : nil)
        .onTapGesture { if isEditable { document.selectedLayerID = layer.id } }
    }

    private var move: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = moveStart ?? CGPoint(x: layer.centerX, y: layer.centerY)
                if moveStart == nil {
                    moveStart = start
                    document.selectedLayerID = layer.id
                }
                document.updateLayer(layer.id) {
                    $0.centerX = (start.x + value.translation.width / scale).rounded()
                    $0.centerY = (start.y + value.translation.height / scale).rounded()
                }
            }
            .onEnded { _ in moveStart = nil }
    }

    private var resize: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = resizeStart ?? layer.width
                if resizeStart == nil { resizeStart = start }
                // Dragging the corner outwards grows the layer about its centre.
                let delta = max(value.translation.width, value.translation.height * layer.aspectRatio) * 2 / scale
                document.updateLayer(layer.id) { $0.width = max(16, (start + delta).rounded()) }
            }
            .onEnded { _ in resizeStart = nil }
    }
}

/// Grey checkerboard meaning "transparent".
struct TransparencyPattern: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 10
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.85)))
            var squares = Path()
            for row in 0...Int(size.height / cell) {
                for column in 0...Int(size.width / cell) where (row + column) % 2 == 0 {
                    squares.addRect(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                }
            }
            context.fill(squares, with: .color(Color(white: 0.7)))
        }
    }
}
