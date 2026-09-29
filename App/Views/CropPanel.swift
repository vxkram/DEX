import MediaModel
import SwiftUI

/// Rotate/flip, aspect presets and exact crop numbers.
struct CropPanel: View {
    @Bindable var document: ImageDocument

    var body: some View {
        ToolPanelBody(document: document) {
            VStack(spacing: 10) {
                PanelSectionHeader("Rotate & flip")
                HStack(spacing: 8) {
                    IconButton("Rotate left", "rotate.left") { document.rotateCounterclockwise() }
                    IconButton("Rotate right", "rotate.right") { document.rotateClockwise() }
                    IconButton("Flip horizontal", "arrow.left.and.right.righttriangle.left.righttriangle.right") { document.flipHorizontally() }
                    IconButton("Flip vertical", "arrow.up.and.down.righttriangle.up.righttriangle.down") { document.flipVertically() }
                }
            }

            if let display = document.displaySize {
                VStack(spacing: 10) {
                    PanelSectionHeader("Aspect ratio")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(CropAspect.allCases) { aspect in
                            Chip(title: aspect.title, isSelected: document.cropAspect == aspect) {
                                document.cropAspect = aspect
                                if let ratio = aspect.ratio(for: display) {
                                    document.geometry.crop = CropMath.centred(ratio: ratio, in: display)
                                }
                            }
                        }
                    }
                }

                VStack(spacing: 10) {
                    PanelSectionHeader("Crop (pixels)")
                    CropFields(document: document, display: display)
                }
            }

            if document.info?.format == .jpeg && document.target == .jpeg && document.geometry.crop != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Exact pixels", isOn: $document.geometry.exactCrop)
                        .toggleStyle(.switch)
                        .tint(Theme.ember)
                    Text(document.geometry.exactCrop
                         ? "Crops exactly where you set it, but re-encodes the JPEG."
                         : "Lossless: JPEG crops snap to the 8/16-pixel blocks the file is made of.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if document.hasEdits {
                Button("Reset crop & rotation", systemImage: "arrow.counterclockwise") {
                    document.resetGeometry()
                    document.cropAspect = .free
                }
                .buttonStyle(.link)
                .tint(Theme.ember)
            }
        }
    }
}

private struct CropFields: View {
    @Bindable var document: ImageDocument
    let display: PixelSize

    var body: some View {
        let crop = document.effectiveCrop ?? PixelRect(x: 0, y: 0, width: display.width, height: display.height)
        Grid(horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                NumberField(label: "W", value: crop.width) { set(crop, width: $0) }
                NumberField(label: "H", value: crop.height) { set(crop, height: $0) }
            }
            GridRow {
                NumberField(label: "X", value: crop.x) { set(crop, x: $0) }
                NumberField(label: "Y", value: crop.y) { set(crop, y: $0) }
            }
        }
    }

    private func set(_ crop: PixelRect, x: Int? = nil, y: Int? = nil, width: Int? = nil, height: Int? = nil) {
        var rect = crop
        rect.x = x ?? rect.x
        rect.y = y ?? rect.y
        rect.width = max(width ?? rect.width, CropMath.minimumSide)
        rect.height = max(height ?? rect.height, CropMath.minimumSide)
        document.cropAspect = .free
        document.geometry.crop = rect.clamped(to: display)
    }
}

/// A labelled integer field that commits on Return or losing focus.
struct NumberField: View {
    let label: String
    let value: Int
    let commit: (Int) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.technicalSmall)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.technical)
                .multilineTextAlignment(.trailing)
                .onSubmit { if let number = Int(text) { commit(number) } else { text = "\(value)" } }
        }
        .onAppear { text = "\(value)" }
        .onChange(of: value) { text = "\(value)" }
    }
}

struct IconButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    init(_ title: String, _ symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct Chip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 28)
                .foregroundStyle(isSelected ? .white : .primary)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? Theme.ember : .white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(isSelected ? 0 : 0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
