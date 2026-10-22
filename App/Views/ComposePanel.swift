import ImageEngine
import MediaModel
import SwiftUI

/// Combine this image with others of any format: layered on top, side by
/// side, stacked, in a grid, or placed freely on a page of any size.
struct ComposePanel: View {
    @Bindable var document: ImageDocument

    var body: some View {
        ToolPanelBody(document: document) {
            // Clicking it again leaves Canvas, back to images on top.
            CanvasButton(isSelected: document.composeMode == .canvas) {
                document.setComposeMode(document.composeMode == .canvas ? .layers : .canvas)
            }

            VStack(spacing: 10) {
                PanelSectionHeader("Layout")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(ComposeMode.allCases.filter { $0 != .canvas }) { mode in
                        ModeButton(mode: mode, isSelected: document.composeMode == mode) {
                            document.setComposeMode(mode)
                        }
                    }
                }
            }

            if document.composeMode == .canvas {
                CanvasSizeSection(document: document)
            }

            ImageList(document: document)

            if document.composeMode.isLayered {
                let canvas = document.layerCanvasSize ?? PixelSize(width: 1, height: 1)
                if document.isBaseSelected, let base = document.framedSize, let info = document.info {
                    LayerControls(title: "Selected: \(info.fileName)", placement: document.basePlacement, native: base,
                                  canvas: canvas) { change in document.updateBase(change) }
                } else if let id = document.selectedLayerID, let layer = document.layers.first(where: { $0.id == id }) {
                    LayerControls(title: "Selected layer", placement: layer.placement, native: layer.editedSize,
                                  canvas: canvas) { change in document.updateLayer(id) { change(&$0.placement) } }
                }
                if document.composeMode == .canvas {
                    BackgroundPicker(document: document,
                                     explanation: "Shows wherever the images don't cover the page. \"None\" is transparent (PNG, WebP, HEIC, TIFF).")
                }
            } else if !document.arrangedImages.isEmpty {
                ArrangementControls(document: document)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await document.addImages(urls) }
            return !urls.isEmpty
        }
    }
}

private struct ModeButton: View {
    let mode: ComposeMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: mode.symbol).font(.system(size: 15, weight: .medium))
                Text(mode.title).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(isSelected ? .white : .primary)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected ? Theme.ember : .white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(isSelected ? 0 : 0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Canvas gets its own large button: a page you design, not a layout.
private struct CanvasButton: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: ComposeMode.canvas.symbol)
                    .font(.system(size: 26, weight: .medium))
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Canvas").font(.title3.weight(.semibold))
                    Text("A4, Story or any size")
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                }
                Spacer(minLength: 0)
                if isSelected { Image(systemName: "checkmark.circle.fill").font(.title3) }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 72)
            .foregroundStyle(isSelected ? .white : .primary)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Theme.ember : .white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? .clear : Theme.ember.opacity(0.5), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Click to leave Canvas" : "Design on a page")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Image list

private struct ImageList: View {
    @Bindable var document: ImageDocument

    var body: some View {
        VStack(spacing: 8) {
            PanelSectionHeader(document.composeMode.isLayered ? "Layers (bottom to top)" : "Images (in order)")
            if document.composeMode == .canvas {
                // Every item, the opened image included, can be restacked.
                let order = document.canvasOrder
                ForEach(Array(order.enumerated()), id: \.offset) { index, id in
                    let up: (() -> Void)? = index > 0 ? { document.moveCanvasItem(at: index, by: -1) } : nil
                    let down: (() -> Void)? = index < order.count - 1 ? { document.moveCanvasItem(at: index, by: 1) } : nil
                    if let id, let layer = document.layers.first(where: { $0.id == id }) {
                        let image = layer.image
                        Row(name: image.info.fileName, format: image.info.format, size: image.info.displaySize,
                            preview: document.extraPreviews[image.url], isSelected: id == document.selectedLayerID,
                            moveUp: up, moveDown: down, remove: { document.removeImage(image) })
                            .onTapGesture { document.selectLayer(id) }
                    } else if id == nil, let info = document.info {
                        Row(name: info.fileName, format: info.format, size: info.displaySize, preview: document.preview,
                            badge: "opened", isSelected: document.isBaseSelected, moveUp: up, moveDown: down)
                            .onTapGesture { document.selectBase() }
                    }
                }
            } else if document.composeMode == .layers {
                // The opened image is the canvas: always at the bottom.
                if let info = document.info {
                    Row(name: info.fileName, format: info.format, size: info.displaySize, preview: document.preview,
                        badge: "base", isSelected: false)
                }
                ForEach(Array(document.layers.enumerated()), id: \.element.id) { index, layer in
                    let image = layer.image
                    Row(name: image.info.fileName, format: image.info.format, size: image.info.displaySize,
                        preview: document.extraPreviews[image.url], isSelected: layer.id == document.selectedLayerID,
                        moveUp: index > 0 ? { document.moveLayer(at: index, by: -1) } : nil,
                        moveDown: index < document.layers.count - 1 ? { document.moveLayer(at: index, by: 1) } : nil,
                        remove: { document.removeImage(image) })
                        .onTapGesture { document.selectLayer(layer.id) }
                }
            } else {
                // Every image, the opened one included, can be reordered.
                let order = document.arrangementOrder
                ForEach(Array(order.enumerated()), id: \.offset) { index, item in
                    let up: (() -> Void)? = index > 0 ? { document.moveArranged(at: index, by: -1) } : nil
                    let down: (() -> Void)? = index < order.count - 1 ? { document.moveArranged(at: index, by: 1) } : nil
                    if let image = item {
                        Row(name: image.info.fileName, format: image.info.format, size: image.info.displaySize,
                            preview: document.extraPreviews[image.url], isSelected: false,
                            moveUp: up, moveDown: down, remove: { document.removeImage(image) })
                    } else if let info = document.info {
                        Row(name: info.fileName, format: info.format, size: info.displaySize, preview: document.preview,
                            badge: "opened", isSelected: false, moveUp: up, moveDown: down)
                    }
                }
            }
            Button {
                document.presentAddImagesPanel()
            } label: {
                Label("Add Images…", systemImage: "plus")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glass)
            if let warning = document.composeWarning {
                HStack(alignment: .top) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    DismissButton { document.composeWarning = nil }
                }
            }
            if document.composedImages.isEmpty {
                Explanation("Or drop images onto the window. Any format.")
            }
        }
    }

    private struct Row: View {
        let name: String
        let format: ImageFormat?
        let size: PixelSize
        let preview: PreviewImage?
        var badge: String?
        let isSelected: Bool
        var moveUp: (() -> Void)?
        var moveDown: (() -> Void)?
        var remove: (() -> Void)?

        var body: some View {
            HStack(spacing: 10) {
                Group {
                    if let preview {
                        Image(decorative: preview.cgImage, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.white.opacity(0.08))
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.callout).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: "\(format?.displayName ?? "?") · \(size.width) × \(size.height)" + (badge.map { " · \($0)" } ?? ""))
                        .font(.technicalSmall)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if moveUp != nil || moveDown != nil {
                    Button("Move up", systemImage: "chevron.up") { moveUp?() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .disabled(moveUp == nil)
                    Button("Move down", systemImage: "chevron.down") { moveDown?() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .disabled(moveDown == nil)
                }
                if let remove { DismissButton(action: remove) }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Theme.ember.opacity(0.18) : .white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Theme.ember : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Layer controls

private struct LayerControls: View {
    let title: String
    let placement: LayerPlacement
    /// The image's own size; its drawn height follows this aspect ratio.
    let native: PixelSize
    let canvas: PixelSize
    let update: @MainActor ((inout LayerPlacement) -> Void) -> Void
    @State private var showsMore = false

    var body: some View {
        let height = placement.width * Double(native.height) / Double(max(native.width, 1))
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                PanelSectionHeader(title)
                    .help("Drag it on the picture to move it; it snaps to the centre. Drag its corner to resize.")
                Button("Centre", systemImage: "align.horizontal.center") {
                    update { $0.centerX = (Double(canvas.width) / 2).rounded(); $0.centerY = (Double(canvas.height) / 2).rounded() }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Put it in the middle")
            }

            LabeledSlider(title: "Size", value: placement.width, range: 16...Double(max(canvas.width, native.width)) * 1.5,
                          display: "\(Int(placement.width.rounded())) × \(Int(height.rounded()))") { width in
                update { $0.width = width.rounded() }
            }
            DisclosureGroup("More", isExpanded: $showsMore) {
                VStack(alignment: .leading, spacing: 14) {
                    Button("Original size (\(native.width) px wide)") {
                        update { $0.width = Double(native.width) }
                    }
                    .buttonStyle(.link)
                    .tint(Theme.ember)
                    .font(.caption)

                    LabeledSlider(title: "Opacity", value: placement.opacity, range: 0...1,
                                  display: "\(Int((placement.opacity * 100).rounded()))%") { opacity in
                        update { $0.opacity = opacity }
                    }
                    LabeledSlider(title: "Rotation", value: placement.rotation, range: -180...180,
                                  display: "\(Int(placement.rotation.rounded()))°") { rotation in
                        // Snap to right angles when close.
                        let snapped = (rotation / 90).rounded() * 90
                        update { $0.rotation = abs(snapped - rotation) < 3 ? snapped : rotation.rounded() }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Position").font(.callout)
                        AnchorGrid { column, row in
                            let margin = Double(min(canvas.width, canvas.height)) * 0.04
                            let halfW = placement.width / 2, halfH = height / 2
                            let xs = [margin + halfW, Double(canvas.width) / 2, Double(canvas.width) - margin - halfW]
                            let ys = [margin + halfH, Double(canvas.height) / 2, Double(canvas.height) - margin - halfH]
                            update { $0.centerX = xs[column].rounded(); $0.centerY = ys[row].rounded() }
                        }
                    }
                }
                .padding(.top, 8)
            }
            .font(.callout)
        }
    }
}

/// Nine buttons that snap the layer to a corner, edge or the centre.
private struct AnchorGrid: View {
    let place: (Int, Int) -> Void

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(0..<3) { row in
                GridRow {
                    ForEach(0..<3) { column in
                        Button {
                            place(column, row)
                        } label: {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.white.opacity(0.1))
                                .overlay(Circle().fill(.primary).frame(width: 5, height: 5))
                                .frame(width: 34, height: 22)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct LabeledSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let display: String
    let change: @MainActor @Sendable (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(verbatim: display).font(.technicalSmall).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: change), in: range)
                .tint(Theme.ember)
        }
    }
}

// MARK: - Arrangement controls

private struct ArrangementControls: View {
    @Bindable var document: ImageDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelSectionHeader("Arrangement")

            if document.composeMode == .grid {
                Stepper(value: $document.gridColumns, in: 2...document.maxGridColumns) {
                    Text(verbatim: "Columns: \(document.gridColumns)").font(.callout)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("Sizes", selection: $document.sizing) {
                    Text("Match sizes").tag(Arrangement.Sizing.matchSmallest)
                    Text("Original sizes").tag(Arrangement.Sizing.original)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Match sizes scales larger images down to line up with the smallest. Original sizes keeps every image's own pixels.")
            }

            if document.sizing == .original || document.composeMode == .grid {
                Picker("Align", selection: $document.alignment) {
                    Text(document.composeMode == .vertical ? "Left" : "Top").tag(Arrangement.Alignment.start)
                    Text("Centre").tag(Arrangement.Alignment.center)
                    Text(document.composeMode == .vertical ? "Right" : "Bottom").tag(Arrangement.Alignment.end)
                }
                .pickerStyle(.segmented)
            }

            LabeledSlider(title: "Spacing", value: Double(document.spacing), range: 0...200, display: "\(document.spacing) px") {
                document.spacing = Int($0.rounded())
            }

            BackgroundPicker(document: document,
                             explanation: "Shows in gaps and around images of different sizes. \"None\" is transparent (PNG, WebP, HEIC, TIFF).")
        }
    }
}

private struct BackgroundPicker: View {
    @Bindable var document: ImageDocument
    let explanation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Background").font(.callout).help(explanation)
            HStack(spacing: 6) {
                Chip(title: "White", isSelected: document.background == .white) { document.background = .white }
                Chip(title: "Black", isSelected: document.background == .black) { document.background = .black }
                Chip(title: "None", isSelected: document.background == .transparent) { document.background = .transparent }
                ColorPicker("Custom", selection: customColor, supportsOpacity: false)
                    .labelsHidden()
            }
        }
    }

    private var customColor: Binding<Color> {
        Binding(
            get: {
                if case .color(let r, let g, let b) = document.background { return Color(red: r, green: g, blue: b) }
                return .white
            },
            set: { color in
                let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .white
                document.background = .color(red: resolved.redComponent, green: resolved.greenComponent, blue: resolved.blueComponent)
            }
        )
    }
}

// MARK: - Canvas size

private struct CanvasSizeSection: View {
    let document: ImageDocument

    private static let presets: [(title: String, detail: String, size: PixelSize?)] = [
        ("A4", "2480 × 3508", PixelSize(width: 2480, height: 3508)),
        ("Letter", "2550 × 3300", PixelSize(width: 2550, height: 3300)),
        ("Square", "1080 × 1080", PixelSize(width: 1080, height: 1080)),
        ("Story", "1080 × 1920", PixelSize(width: 1080, height: 1920)),
        ("Wide", "1920 × 1080", PixelSize(width: 1920, height: 1080)),
        ("Photo", "its own size", nil),
    ]

    var body: some View {
        let size = document.canvasSize
        VStack(alignment: .leading, spacing: 10) {
            PanelSectionHeader("Page size")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Self.presets, id: \.title) { preset in
                    let target = preset.size ?? document.framedSize
                    TwoLineChip(title: preset.title, subtitle: preset.detail, isSelected: target == size) {
                        if let target { document.setCanvasSize(target) }
                    }
                }
            }
            DisclosureGroup("Custom size") {
                HStack(spacing: 10) {
                    NumberField(label: "W", value: size.width) { document.setCanvasSize(PixelSize(width: $0, height: size.height)) }
                    NumberField(label: "H", value: size.height) { document.setCanvasSize(PixelSize(width: size.width, height: $0)) }
                }
                .padding(.top, 8)
            }
            .font(.callout)
        }
    }
}
