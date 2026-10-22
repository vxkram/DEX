import MediaModel
import SwiftUI

/// Rotate/flip and aspect presets, cropped or fitted.
struct CropPanel: View {
    @Bindable var document: ImageDocument

    var body: some View {
        ToolPanelBody(document: document) {
            if let layer = document.cropLayer {
                CropSubjectBanner(document: document, name: layer.image.info.fileName)
            }

            VStack(spacing: 10) {
                PanelSectionHeader(document.cropLayer == nil ? "Rotate & flip" : "Rotate")
                HStack(spacing: 8) {
                    IconButton("Rotate left", "rotate.left") { document.rotateSubject(clockwise: false) }
                    IconButton("Rotate right", "rotate.right") { document.rotateSubject(clockwise: true) }
                    if document.cropLayer == nil {
                        IconButton("Flip horizontal", "arrow.left.and.right.righttriangle.left.righttriangle.right") { document.flipHorizontally() }
                        IconButton("Flip vertical", "arrow.up.and.down.righttriangle.up.righttriangle.down") { document.flipVertically() }
                    }
                }
            }

            VStack(spacing: 10) {
                PanelSectionHeader("Aspect ratio")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(CropAspect.allCases) { aspect in
                        Chip(title: aspect.title, isSelected: document.subjectAspect == aspect) {
                            document.setCropAspect(aspect)
                        }
                    }
                }
                if document.subjectAspect.ratio != nil {
                    Picker("Mode", selection: Binding(get: { document.isFitting }, set: { document.setFitting($0) })) {
                        Text("Crop").tag(false)
                        Text("Fit").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.large)
                    .help("Crop cuts the picture to the shape. Fit keeps all of it and adds space around it; the photo's own pixels aren't touched.")
                }
            }

            if document.isFitting {
                FitBackgroundPicker(document: document)
            }

            if document.cropLayer == nil && document.info?.format == .jpeg && document.target == .jpeg && document.geometry.crop != nil {
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

            if document.subjectHasEdits {
                Button(document.isFitting ? "Reset fit & rotation" : "Reset crop & rotation", systemImage: "arrow.counterclockwise") {
                    document.resetSubject()
                }
                .buttonStyle(.link)
                .tint(Theme.ember)
            }
        }
    }
}

/// Says which image Crop is working on when it isn't the opened photo.
private struct CropSubjectBanner: View {
    let document: ImageDocument
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(verbatim: "Cropping \(name)").lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: "scope")
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(Theme.ember)
            if let info = document.info {
                Button("Crop \(info.fileName) instead") { document.selectBase() }
                    .buttonStyle(.link)
                    .tint(Theme.ember)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.ember.opacity(0.12)))
    }
}

/// What fills the space Fit adds around the picture.
private struct FitBackgroundPicker: View {
    let document: ImageDocument

    var body: some View {
        let current = document.subjectFrame?.background
        VStack(alignment: .leading, spacing: 8) {
            PanelSectionHeader("Background")
            HStack(spacing: 6) {
                Chip(title: "Blur", isSelected: current == .blur) { document.setFitBackground(.blur) }
                Chip(title: "White", isSelected: current == .white) { document.setFitBackground(.white) }
                Chip(title: "Black", isSelected: current == .black) { document.setFitBackground(.black) }
                Chip(title: "None", isSelected: current == .transparent) { document.setFitBackground(.transparent) }
                ColorPicker("Custom colour", selection: customColor, supportsOpacity: false)
                    .labelsHidden()
                    .help("Custom colour")
            }
            if current == .transparent && !document.target.supportsAlpha {
                Explanation("\(document.target.displayName) can't be transparent: saves as white.")
            }
        }
    }

    private var customColor: Binding<Color> {
        Binding(
            get: {
                if case .color(let r, let g, let b) = document.subjectFrame?.background { return Color(red: r, green: g, blue: b) }
                return .white
            },
            set: { color in
                let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .white
                document.setFitBackground(.color(red: resolved.redComponent, green: resolved.greenComponent, blue: resolved.blueComponent))
            }
        )
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
