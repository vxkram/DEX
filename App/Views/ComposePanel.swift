import ImageEngine
import MediaModel
import SwiftUI

/// Combine this image with others of any format: layered on top, side by
/// side, stacked or in a grid.
struct ComposePanel: View {
    @Bindable var document: ImageDocument

    var body: some View {
        ToolPanelBody(document: document) {
            VStack(spacing: 10) {
                PanelSectionHeader("Layout")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(ComposeMode.allCases) { mode in
                        ModeButton(mode: mode, isSelected: document.composeMode == mode) {
                            document.setComposeMode(mode)
                        }
                    }
                }
            }

            ImageList(document: document)

            if document.composeMode == .layers {
                if let id = document.selectedLayerID, let layer = document.layers.first(where: { $0.id == id }) {
                    LayerControls(document: document, layer: layer)
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

// MARK: - Image list

private struct ImageList: View {
    @Bindable var document: ImageDocument

    var body: some View {
        VStack(spacing: 8) {
            PanelSectionHeader(document.composeMode == .layers ? "Layers (top last)" : "Images (in order)")
            if let info = document.info {
                Row(name: info.fileName, format: info.format, size: info.displaySize, preview: document.preview,
                    isBase: true, isSelected: false)
            }
            ForEach(document.composedImages, id: \.url) { image in
                let layerID = document.layers.first { $0.image == image }?.id
                Row(name: image.info.fileName, format: image.info.format, size: image.info.displaySize,
                    preview: document.extraPreviews[image.url], isBase: false,
                    isSelected: layerID != nil && layerID == document.selectedLayerID,
                    moveUp: { document.move(image, by: -1) }, moveDown: { document.move(image, by: 1) },
                    remove: { document.removeImage(image) })
                    .onTapGesture { if let layerID { document.selectedLayerID = layerID } }
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
            Explanation(document.composedImages.isEmpty
                        ? "Add one or more images, or drop them onto the window. JPEG, PNG, HEIC, WebP, AVIF… any mix works."
                        : "Formats don't matter: everything is decoded and colour-matched, then saved in the format you pick in Convert.")
        }
    }

    private struct Row: View {
        let name: String
        let format: ImageFormat?
        let size: PixelSize
        let preview: PreviewImage?
        let isBase: Bool
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
                    Text(verbatim: "\(format?.displayName ?? "?") · \(size.width) × \(size.height)" + (isBase ? " · base" : ""))
                        .font(.technicalSmall)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if !isBase {
                    Button("Move up", systemImage: "chevron.up") { moveUp?() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                    Button("Move down", systemImage: "chevron.down") { moveDown?() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                    DismissButton { remove?() }
                }
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
    let document: ImageDocument
    let layer: OverlayLayer

    var body: some View {
        let canvas = document.croppedSize ?? PixelSize(width: 1, height: 1)
        VStack(alignment: .leading, spacing: 14) {
            PanelSectionHeader("Selected layer")
            Explanation("Drag it on the photo to move it; drag its corner to resize.")

            LabeledSlider(title: "Size", value: layer.width, range: 16...Double(canvas.width) * 1.5,
                          display: "\(Int(layer.width.rounded())) × \(Int(layer.height.rounded()))") { width in
                document.updateLayer(layer.id) { $0.width = width.rounded() }
            }
            Button("Original size (\(layer.image.info.displaySize.width) px wide)") {
                document.updateLayer(layer.id) { $0.width = Double($0.image.info.displaySize.width) }
            }
            .buttonStyle(.link)
            .tint(Theme.ember)
            .font(.caption)

            LabeledSlider(title: "Opacity", value: layer.opacity, range: 0...1,
                          display: "\(Int((layer.opacity * 100).rounded()))%") { opacity in
                document.updateLayer(layer.id) { $0.opacity = opacity }
            }
            LabeledSlider(title: "Rotation", value: layer.rotation, range: -180...180,
                          display: "\(Int(layer.rotation.rounded()))°") { rotation in
                // Snap to right angles when close.
                let snapped = (rotation / 90).rounded() * 90
                document.updateLayer(layer.id) { $0.rotation = abs(snapped - rotation) < 3 ? snapped : rotation.rounded() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Position").font(.callout)
                AnchorGrid { column, row in
                    let margin = Double(min(canvas.width, canvas.height)) * 0.04
                    let halfW = layer.width / 2, halfH = layer.height / 2
                    let xs = [margin + halfW, Double(canvas.width) / 2, Double(canvas.width) - margin - halfW]
                    let ys = [margin + halfH, Double(canvas.height) / 2, Double(canvas.height) - margin - halfH]
                    document.updateLayer(layer.id) { $0.centerX = xs[column].rounded(); $0.centerY = ys[row].rounded() }
                }
            }
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
                Stepper(value: $document.gridColumns, in: 2...8) {
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
                Explanation(document.sizing == .matchSmallest
                            ? "Larger images are scaled down so they line up with the smallest. Nothing is enlarged."
                            : "Every image keeps its own pixels; smaller ones sit in the space according to alignment.")
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

            VStack(alignment: .leading, spacing: 8) {
                Text("Background").font(.callout)
                HStack(spacing: 6) {
                    Chip(title: "White", isSelected: document.background == .white) { document.background = .white }
                    Chip(title: "Black", isSelected: document.background == .black) { document.background = .black }
                    Chip(title: "None", isSelected: document.background == .transparent) { document.background = .transparent }
                    ColorPicker("Custom", selection: customColor, supportsOpacity: false)
                        .labelsHidden()
                }
                Explanation("Shows in gaps and around images of different sizes. \"None\" is transparent (PNG, WebP, HEIC, TIFF).")
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
