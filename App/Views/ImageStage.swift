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
            if let preview = document.stagePreview, let display = document.displaySize {
                Group {
                    // Crop edits the opened photo on its own, even when it
                    // sits on a canvas or among other images.
                    if isCropping, let layer = document.cropLayer {
                        layerCropStage(layer, available: available)
                    } else if isCropping && !document.isFitting {
                        croppingStage(preview, display: display, available: available)
                    } else if document.composition != nil && !isCropping {
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
            .onDisappear { document.releaseLoupe() }
            .onChange(of: document.geometry.orientation) { document.prepareLoupe() }
    }

    /// Crop on an added image: its own crop box, or its Fit result.
    @ViewBuilder
    private func layerCropStage(_ layer: OverlayLayer, available: CGSize) -> some View {
        let display = layer.image.info.displaySize
        if let extra = document.extraPreviews[layer.image.url] {
            if document.isFitting {
                let scale = min(available.width / CGFloat(layer.editedSize.width), available.height / CGFloat(layer.editedSize.height))
                EditedBase(preview: extra, orientation: .identity, display: display,
                           crop: layer.crop ?? PixelRect(x: 0, y: 0, width: display.width, height: display.height),
                           frame: layer.frame, opaque: false, scale: scale)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                let scale = min(available.width / CGFloat(display.width), available.height / CGFloat(display.height))
                let frame = CGSize(width: CGFloat(display.width) * scale, height: CGFloat(display.height) * scale)
                OrientedImage(image: extra, orientation: .identity, size: frame)
                    .overlay { CropOverlay(document: document, display: display, scale: scale) }
                    .frame(width: frame.width, height: frame.height)
            }
        } else {
            ProgressView()
        }
    }

    private func resultStage(_ preview: PreviewImage, display: PixelSize, available: CGSize) -> some View {
        let crop = document.effectiveCrop ?? PixelRect(x: 0, y: 0, width: display.width, height: display.height)
        let framed = document.framedSize ?? crop.size
        let scale = min(available.width / CGFloat(framed.width), available.height / CGFloat(framed.height))
        return EditedBase(preview: preview, orientation: document.geometry.orientation, display: display, crop: crop,
                          frame: document.geometry.frame, opaque: !document.target.supportsAlpha, scale: scale)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
            .shadow(color: .black.opacity(0.45), radius: 36, y: 22)
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
    private var shown: PixelRect { draft ?? document.subjectCrop ?? full }

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

            ForEach(CropHandle.edges.filter { document.subjectAspect.ratio == nil || $0.isCorner }, id: \.self) { handle in
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
                                           ratio: document.subjectAspect.ratio)
                draft = rect
                // The loupe reads the opened photo's full-resolution pixels.
                if handle != .move && document.cropLayer == nil { document.cropDrag = CropDrag(handle: handle, rect: rect) }
            }
            .onEnded { _ in
                if let draft { document.setSubjectCrop(draft == full ? nil : draft) }
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
        if let preview = document.stagePreview, let display = document.displaySize, let base = document.framedSize {
            let crop = document.effectiveCrop ?? PixelRect(x: 0, y: 0, width: display.width, height: display.height)
            let layout = canvasLayout(base: base)
            let scale = min(available.width / CGFloat(layout.canvas.width), available.height / CGFloat(layout.canvas.height))

            ZStack(alignment: .topLeading) {
                backgroundView
                if document.composeMode == .canvas {
                    // Bottom to top, the opened image among the layers.
                    ForEach(document.canvasOrder, id: \.self) { id in
                        if let id, let layer = document.layers.first(where: { $0.id == id }) {
                            LayerView(document: document, layer: layer, canvas: layout.canvas, scale: scale,
                                      isEditable: document.tool == .compose)
                        } else if id == nil {
                            let placement = document.basePlacement
                            PlacedItem(placement: placement, aspectRatio: Double(base.width) / Double(max(base.height, 1)),
                                       canvas: layout.canvas, scale: scale, isEditable: document.tool == .compose,
                                       isSelected: document.isBaseSelected, select: { document.selectBase() },
                                       update: { document.updateBase($0) }, guides: { document.centreGuides = $0 }) {
                                EditedBase(preview: preview, orientation: document.geometry.orientation, display: display, crop: crop,
                                           frame: document.geometry.frame, opaque: !document.target.supportsAlpha,
                                           scale: scale * placement.width / CGFloat(base.width))
                            }
                        }
                    }
                } else {
                    // The (rotated, cropped) base.
                    // In "match sizes" arrangements the base itself may be scaled.
                    let baseScale = scale * CGFloat(layout.frames[baseIndex].width) / CGFloat(base.width)
                    let baseFrame = layout.frames[baseIndex]
                    EditedBase(preview: preview, orientation: document.geometry.orientation, display: display, crop: crop,
                               frame: document.geometry.frame, opaque: !document.target.supportsAlpha, scale: baseScale)
                        .frame(width: CGFloat(baseFrame.width) * scale, height: CGFloat(baseFrame.height) * scale)
                        .offset(x: CGFloat(baseFrame.x) * scale, y: CGFloat(baseFrame.y) * scale)
                }

                if document.composeMode == .layers {
                    ForEach(document.layers) { layer in
                        LayerView(document: document, layer: layer, canvas: layout.canvas, scale: scale,
                                  isEditable: document.tool == .compose)
                    }
                } else if document.composeMode != .canvas {
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
            .overlay { CentreGuideLines(guides: document.centreGuides) }
            .clipped()
            .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
            .shadow(color: .black.opacity(0.45), radius: 36, y: 22)
        }
    }

    private var baseIndex: Int {
        document.composeMode.isLayered ? 0 : document.arrangement.clampedBasePosition
    }

    private func canvasLayout(base: PixelSize) -> ArrangementLayout.Result {
        if document.composeMode == .canvas {
            return ArrangementLayout.Result(canvas: document.canvasSize, frames: [])
        }
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
struct CroppedBase: View {
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

/// The base as edited: rotated/flipped, cropped and, with Fit, on its
/// canvas with the background around it.
struct EditedBase: View {
    let preview: PreviewImage
    let orientation: Orientation
    let display: PixelSize
    let crop: PixelRect
    let frame: Framing?
    /// The format can't be transparent: "None" shows as white, as exported.
    let opaque: Bool
    let scale: CGFloat

    var body: some View {
        let cropped = CroppedBase(preview: preview, orientation: orientation, display: display, crop: crop, scale: scale)
        if let frame {
            let (canvas, rect) = frame.canvas(for: crop.size)
            let size = CGSize(width: CGFloat(canvas.width) * scale, height: CGFloat(canvas.height) * scale)
            ZStack(alignment: .topLeading) {
                background(frame.background, cropped: cropped, size: size)
                cropped.offset(x: CGFloat(rect.x) * scale, y: CGFloat(rect.y) * scale)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
        } else {
            cropped
        }
    }

    @ViewBuilder
    private func background(_ background: Framing.Background, cropped: CroppedBase, size: CGSize) -> some View {
        switch background {
        case .transparent:
            if opaque { Color.white } else { TransparencyPattern() }
        case .color(let red, let green, let blue):
            Color(red: red, green: green, blue: blue)
        case .blur:
            let cover = max(size.width / CGFloat(crop.width), size.height / CGFloat(crop.height))
            CroppedBase(preview: preview, orientation: orientation, display: display, crop: crop, scale: cover)
                .blur(radius: max(size.width, size.height) / 32, opaque: true)
                .frame(width: size.width, height: size.height)
                .overlay(Color.black.opacity(0.18))
        }
    }
}

/// One overlay layer: drag to move, drag the corner to resize.
private struct LayerView: View {
    let document: ImageDocument
    let layer: OverlayLayer
    let canvas: PixelSize
    let scale: CGFloat
    let isEditable: Bool

    var body: some View {
        PlacedItem(placement: layer.placement, aspectRatio: layer.aspectRatio, canvas: canvas, scale: scale,
                   isEditable: isEditable, isSelected: document.selectedLayerID == layer.id && !document.isBaseSelected,
                   select: { document.selectLayer(layer.id) },
                   update: { change in document.updateLayer(layer.id) { change(&$0.placement) } },
                   guides: { document.centreGuides = $0 }) {
            if let preview = document.extraPreviews[layer.image.url] {
                // With its own crop and Fit, as it will be exported.
                let display = layer.image.info.displaySize
                EditedBase(preview: preview, orientation: .identity, display: display,
                           crop: layer.crop ?? PixelRect(x: 0, y: 0, width: display.width, height: display.height),
                           frame: layer.frame, opaque: false,
                           scale: scale * layer.width / CGFloat(max(layer.editedSize.width, 1)))
            } else {
                Rectangle().fill(.white.opacity(0.15))
            }
        }
    }
}

/// Anything placed on a canvas: drawn at its placement, dragged to move,
/// its corner dragged to resize about the centre.
private struct PlacedItem<Content: View>: View {
    let placement: LayerPlacement
    /// Width / height of what is drawn.
    let aspectRatio: Double
    let canvas: PixelSize
    let scale: CGFloat
    let isEditable: Bool
    let isSelected: Bool
    let select: () -> Void
    let update: ((inout LayerPlacement) -> Void) -> Void
    /// Reports when a drag is snapped to the page's centre lines.
    let guides: (CentreGuides) -> Void
    @ViewBuilder let content: Content

    @State private var moveStart: CGPoint?
    @State private var resizeStart: Double?

    var body: some View {
        let isSelected = isEditable && isSelected
        let size = CGSize(width: placement.width * scale, height: placement.width / aspectRatio * scale)
        content
            .frame(width: size.width, height: size.height)
            .opacity(placement.opacity)
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
            .rotationEffect(.degrees(placement.rotation))
            .position(x: placement.centerX * scale, y: placement.centerY * scale)
            .gesture(isEditable ? move : nil)
            .onTapGesture { if isEditable { select() } }
    }

    private var move: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = moveStart ?? CGPoint(x: placement.centerX, y: placement.centerY)
                if moveStart == nil {
                    moveStart = start
                    select()
                }
                // Within a few screen points of the centre, it snaps there.
                let reach = 8 / scale
                let midX = Double(canvas.width) / 2, midY = Double(canvas.height) / 2
                var x = start.x + value.translation.width / scale
                var y = start.y + value.translation.height / scale
                let snapsX = abs(x - midX) < reach, snapsY = abs(y - midY) < reach
                if snapsX { x = midX }
                if snapsY { y = midY }
                update {
                    $0.centerX = x.rounded()
                    $0.centerY = y.rounded()
                }
                guides(CentreGuides(vertical: snapsX, horizontal: snapsY))
            }
            .onEnded { _ in
                moveStart = nil
                guides(CentreGuides())
            }
    }

    private var resize: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = resizeStart ?? placement.width
                if resizeStart == nil { resizeStart = start }
                // Dragging the corner outwards grows the item about its centre.
                let delta = max(value.translation.width, value.translation.height * aspectRatio) * 2 / scale
                update { $0.width = max(16, (start + delta).rounded()) }
            }
            .onEnded { _ in resizeStart = nil }
    }
}

/// Thin lines through the page's centre while an item is snapped to it.
private struct CentreGuideLines: View {
    let guides: CentreGuides

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                if guides.vertical {
                    path.move(to: CGPoint(x: proxy.size.width / 2, y: 0))
                    path.addLine(to: CGPoint(x: proxy.size.width / 2, y: proxy.size.height))
                }
                if guides.horizontal {
                    path.move(to: CGPoint(x: 0, y: proxy.size.height / 2))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height / 2))
                }
            }
            .stroke(Theme.ember, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .allowsHitTesting(false)
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
