import ImageEngine
import MediaModel
import SwiftUI

/// Everything DEX knows about the open file.
struct InfoPanel: View {
    let document: ImageDocument

    var body: some View {
        ScrollView {
            if let pdf = document.pdfInfo {
                VStack(spacing: 0) {
                    Fact("Format", "PDF")
                    Fact("Pages", "\(pdf.pageCount)")
                    if let first = pdf.pageSizes.first {
                        Fact("Page 1", "\(Int(first.width)) × \(Int(first.height)) pt")
                    }
                    Fact("File size", ByteCountFormatter.string(fromByteCount: pdf.fileSize, countStyle: .file))
                    Fact("Protected", pdf.isEncrypted ? "Yes" : "No")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            if let info = document.info {
                VStack(spacing: 0) {
                    Fact("Format", info.format?.displayName ?? info.typeIdentifier)
                    Fact("Dimensions", "\(info.displayWidth) × \(info.displayHeight)")
                    if info.orientation != 1 {
                        Fact("Stored as", "\(info.pixelWidth) × \(info.pixelHeight), orientation \(info.orientation)")
                    }
                    Fact("File size", ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file))
                    Fact("Colour profile", info.colorProfile ?? info.colorModel ?? "None")
                    Fact("Bit depth", info.bitsPerComponent.map { "\($0)-bit" } ?? "Unknown")
                    Fact("Transparency", info.hasAlpha ? "Yes" : "No")
                    Fact("HDR", info.hasHDRGainMap ? "Gain map" : "No")
                    if info.isAnimated {
                        Fact("Frames", "\(info.frameCount)")
                    }
                    Fact("Location", info.hasGPS ? "Present" : "None", highlight: info.hasGPS)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            InstalledModels(store: document.enhanceStore)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .scrollIndicators(.never)
    }
}

/// The Enhance models on this Mac, each with its size and a Delete button.
private struct InstalledModels: View {
    let store: EnhanceStore

    var body: some View {
        let models = EnhanceModel.allCases.filter(store.isInstalled)
        if !models.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                PanelSectionHeader("AI models")
                ForEach(models) { model in
                    HStack {
                        Text(model.title).font(.callout)
                        Spacer()
                        Text(verbatim: EnhanceModels.installedSize(model).map {
                            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                        } ?? "")
                        .font(.technicalSmall)
                        .foregroundStyle(.secondary)
                        Button("Delete", systemImage: "trash") { store.remove(model) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Delete \(model.title). Enhance downloads it again when needed.")
                    }
                    .help(model.credit)
                }
            }
            .padding(.top, 8)
        }
    }
}

private struct Fact: View {
    let label: String
    let value: String
    let highlight: Bool

    init(_ label: String, _ value: String, highlight: Bool = false) {
        self.label = label
        self.value = value
        self.highlight = highlight
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(verbatim: value)
                .font(.technical)
                .foregroundStyle(highlight ? .orange : .primary)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }
}
