import MediaModel
import SwiftUI

/// Everything DEX knows about the open file.
struct InfoPanel: View {
    let document: ImageDocument

    var body: some View {
        ScrollView {
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
        }
        .scrollIndicators(.never)
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
