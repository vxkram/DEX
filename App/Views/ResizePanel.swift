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
                    Explanation("The exact width and height of the saved image. With the link on, changing one keeps the proportions so nothing is stretched.")
                }

                VStack(spacing: 10) {
                    PanelSectionHeader("Scale")
                    Explanation("A percentage of the original size: 50% is half as wide and half as tall (a quarter of the pixels).")
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
                    Explanation("Makes the longer side exactly this many pixels and scales the other to match. Handy for uploads.")
                    HStack(spacing: 6) {
                        ForEach([(1080, "Social"), (2048, "Web"), (3840, "4K")], id: \.0) { edge, use in
                            let size = longEdge(base, edge)
                            Button { apply(size, base: base) } label: {
                                VStack(spacing: 1) {
                                    Text(verbatim: "\(edge)").font(.system(.caption, design: .monospaced, weight: .semibold))
                                    Text(use).font(.caption2).foregroundStyle(current == size ? .white.opacity(0.85) : .secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .foregroundStyle(current == size ? .white : .primary)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(current == size ? Theme.ember : .white.opacity(0.07)))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(current == size ? 0 : 0.08)))
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(!allowsEnlarging && max(base.width, base.height) < edge)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Allow enlarging", isOn: $allowsEnlarging)
                        .toggleStyle(.switch)
                        .tint(Theme.ember)
                        .font(.callout)
                    Explanation("Off by default: making an image bigger than the original only stretches it and adds blur, never detail.")
                }
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

/// A short, plain-language note under a setting.
struct Explanation: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
