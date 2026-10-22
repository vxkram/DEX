import ImageEngine
import MediaModel
import SwiftUI

/// AI enhance: a larger, sharper, cleaner picture. Models download on
/// first use; the result is always marked as AI-made.
struct EnhancePanel: View {
    @Bindable var document: ImageDocument

    private var store: EnhanceStore { document.enhanceStore }

    var body: some View {
        ToolPanelBody(document: document) {
            Toggle("Enhance with AI", isOn: Binding(get: { document.geometry.enhance != nil },
                                                    set: { document.setEnhancing($0) }))
                .toggleStyle(.switch)
                .tint(Theme.ember)
                .font(.headline)
                .help("Upscales on this Mac with Real-ESRGAN. Nothing is uploaded.")

            if let enhance = document.geometry.enhance {
                VStack(spacing: 10) {
                    PanelSectionHeader("Style")
                    HStack(spacing: 6) {
                        StyleChip("Fast", "photos", .fast, enhance)
                        StyleChip("Best", "photos, finest", .best, enhance)
                        StyleChip("Anime", "drawings", .anime, enhance)
                    }
                }

                VStack(spacing: 10) {
                    PanelSectionHeader("Size")
                    HStack(spacing: 6) {
                        ForEach([2, 4], id: \.self) { scale in
                            let size = document.croppedSize.map { PixelSize(width: $0.width * scale, height: $0.height * scale) }
                            TwoLineChip(title: "\(scale)×", subtitle: size.map { "\($0.width) × \($0.height)" } ?? "",
                                        isSelected: enhance.scale == scale) {
                                document.geometry.enhance?.scale = scale
                            }
                        }
                    }
                }

                if enhance.style == .fast {
                    VStack(spacing: 10) {
                        PanelSectionHeader("Noise removal")
                        Picker("Noise removal", selection: Binding(get: { enhance.denoise },
                                                                   set: { document.geometry.enhance?.denoise = $0 })) {
                            Text("Low").tag(Enhancement.Denoise.low)
                            Text("Medium").tag(Enhancement.Denoise.medium)
                            Text("High").tag(Enhancement.Denoise.high)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .help("Higher removes more grain and JPEG blocks, and smooths fine texture more.")
                    }
                }

                Toggle(isOn: Binding(get: { enhance.faces }, set: { document.geometry.enhance?.faces = $0 })) {
                    HStack(spacing: 6) {
                        Text("Restore faces")
                        if !store.isInstalled(.faces) {
                            Text(verbatim: size(EnhanceModel.faces.bytes)).font(.technicalSmall).foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.switch)
                .tint(Theme.ember)
                .help("Redraws faces with GFPGAN. They can come out smoother or a little different.")

                ModelDownloads(store: store, needed: enhance.models)
            }
        }
    }

    @ViewBuilder
    private func StyleChip(_ title: String, _ detail: String, _ style: Enhancement.Style, _ enhance: Enhancement) -> some View {
        TwoLineChip(title: title, subtitle: detail, isSelected: enhance.style == style) {
            document.geometry.enhance?.style = style
        }
    }
}

/// One line per model still to download, or the progress of downloads.
private struct ModelDownloads: View {
    let store: EnhanceStore
    let needed: [EnhanceModel]

    var body: some View {
        let missing = store.missing(needed)
        if !missing.isEmpty || store.isDownloading || store.error != nil {
            VStack(alignment: .leading, spacing: 10) {
                if store.isDownloading {
                    ForEach(EnhanceModel.allCases.filter { store.downloading[$0] != nil }) { model in
                        HStack {
                            Text(model.title).font(.callout)
                            ProgressView(value: store.downloading[model] ?? 0).tint(Theme.ember)
                        }
                    }
                    Button("Cancel") { store.cancel() }.buttonStyle(.link).tint(Theme.ember)
                } else if !missing.isEmpty {
                    let total = missing.map(\.bytes).reduce(0, +)
                    Button {
                        store.download(missing)
                    } label: {
                        Label("Download \(missing.map(\.title).joined(separator: " + ")) · \(size(total))",
                              systemImage: "arrow.down.circle")
                            .font(.callout.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.ember)
                    .help("One-time download from DEX's GitHub, checked against its fingerprint. Your images never leave this Mac.")
                }
                if let error = store.error {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        DismissButton { store.error = nil }
                    }
                }
            }
        }
    }
}

private func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
