import MediaModel
import SwiftUI

/// Format, metadata and quality settings with the live quality verdict.
struct ConvertPanel: View {
    @Bindable var document: ImageDocument
    @State private var showsAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(spacing: 10) {
                        PanelSectionHeader("Format")
                        FormatGrid(formats: document.writableFormats, selection: $document.target)
                    }

                    VStack(spacing: 10) {
                        PanelSectionHeader("Metadata")
                        Picker("Metadata", selection: $document.metadata) {
                            Text("Keep").tag(MetadataPolicy.keepAll)
                            Text("No location").tag(MetadataPolicy.removeLocation)
                            Text("None").tag(MetadataPolicy.removeAll)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .controlSize(.large)
                    }

                    if document.target.hasLossyMode {
                        DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                            QualityControl(quality: $document.quality, target: document.target)
                                .padding(.top, 10)
                        }
                        .font(.callout)
                    }

                    ResultSection(document: document)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)

            ExportFooter(document: document)
        }
    }
}

// MARK: - Format grid

private struct FormatGrid: View {
    let formats: [ImageFormat]
    @Binding var selection: ImageFormat

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(formats, id: \.self) { format in
                let isSelected = selection == format
                Button {
                    selection = format
                } label: {
                    Text(format.displayName)
                        .font(.system(.callout, design: .monospaced, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .foregroundStyle(isSelected ? .white : .primary)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isSelected ? Theme.ember : .white.opacity(0.07))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.white.opacity(isSelected ? 0 : 0.08))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

// MARK: - Quality

private struct QualityControl: View {
    @Binding var quality: QualityPreference
    let target: ImageFormat

    /// At the top of the slider WebP switches to lossless encoding.
    private var maximumLabel: String {
        target.supportsLossless ? "Max · Lossless" : "Max · 95"
    }

    var body: some View {
        let value = Binding<Double>(
            get: { quality.lossyValue },
            set: { quality = $0 >= QualityPreference.maximumLossyQuality ? .maximum : .custom($0) }
        )
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Quality")
                Spacer()
                Text(quality == .maximum ? maximumLabel : "\(Int((value.wrappedValue * 100).rounded()))")
                    .font(.technical)
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0.4...QualityPreference.maximumLossyQuality)
                .tint(Theme.ember)
            Text("Lower quality means smaller files but less detail.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
