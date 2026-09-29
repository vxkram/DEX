import MediaModel
import SwiftUI

/// Output size, with an aspect lock and quick presets. Never enlarges
/// unless asked to.
struct ResizePanel: View {
    @Bindable var document: ImageDocument
    @State private var locksAspect = true
    @State private var allowsEnlarging = false

    var body: some View {
        ToolPanelBody(document: document) {
            if let base = document.croppedSize {
                let current = document.geometry.resize ?? base

                VStack(spacing: 10) {
                    PanelSectionHeader("Size (pixels)")
                    HStack(spacing: 8) {
                        NumberField(label: "W", value: current.width) { set(width: $0, base: base) }
                        Button {
                            locksAspect.toggle()
                        } label: {
                            Image(systemName: locksAspect ? "link" : "link.badge.plus")
                                .foregroundStyle(locksAspect ? Theme.ember : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(locksAspect ? "Aspect ratio locked" : "Aspect ratio unlocked")
                        NumberField(label: "H", value: current.height) { set(height: $0, base: base) }
                    }
                    Text(verbatim: "Original \(base.width) × \(base.height)")
                        .font(.technicalSmall)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(spacing: 10) {
                    PanelSectionHeader("Scale")
                    HStack(spacing: 6) {
                        ForEach([25, 50, 75, 100], id: \.self) { percent in
                            Chip(title: "\(percent)%", isSelected: current == scaled(base, percent: percent)) {
                                apply(scaled(base, percent: percent), base: base)
                            }
                        }
                    }
                }

                VStack(spacing: 10) {
                    PanelSectionHeader("Long edge")
                    HStack(spacing: 6) {
                        ForEach([1080, 2048, 3840], id: \.self) { edge in
                            let size = longEdge(base, edge)
                            Chip(title: "\(edge)", isSelected: current == size) { apply(size, base: base) }
                                .disabled(!allowsEnlarging && max(base.width, base.height) < edge)
                        }
                    }
                }

                Toggle("Allow enlarging", isOn: $allowsEnlarging)
                    .toggleStyle(.switch)
                    .tint(Theme.ember)
                    .font(.callout)
            }
        }
    }

    private func scaled(_ base: PixelSize, percent: Int) -> PixelSize {
        PixelSize(width: max(base.width * percent / 100, 1), height: max(base.height * percent / 100, 1))
    }

    private func longEdge(_ base: PixelSize, _ edge: Int) -> PixelSize {
        let factor = Double(edge) / Double(max(base.width, base.height))
        return PixelSize(width: max(Int((Double(base.width) * factor).rounded()), 1),
                         height: max(Int((Double(base.height) * factor).rounded()), 1))
    }

    private func set(width: Int? = nil, height: Int? = nil, base: PixelSize) {
        let current = document.geometry.resize ?? base
        var size = PixelSize(width: max(width ?? current.width, 1), height: max(height ?? current.height, 1))
        if locksAspect {
            let ratio = Double(base.width) / Double(base.height)
            if width != nil { size.height = max(Int((Double(size.width) / ratio).rounded()), 1) }
            if height != nil { size.width = max(Int((Double(size.height) * ratio).rounded()), 1) }
        }
        apply(size, base: base)
    }

    /// Clamps to the original size unless enlarging is allowed: DEX
    /// never upscales silently.
    private func apply(_ size: PixelSize, base: PixelSize) {
        var size = size
        if !allowsEnlarging && (size.width > base.width || size.height > base.height) {
            let factor = min(Double(base.width) / Double(size.width), Double(base.height) / Double(size.height))
            size = PixelSize(width: Int((Double(size.width) * factor).rounded()), height: Int((Double(size.height) * factor).rounded()))
        }
        document.geometry.resize = size == base ? nil : size
    }
}
