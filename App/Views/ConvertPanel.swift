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
                        FormatGrid(formats: document.writableFormats, selection: $document.target, isPDF: $document.exportAsPDF)
                    }

                    if document.exportAsPDF {
                        PDFExportSettings(document: document)
                    } else {
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

                        DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                            AdvancedSettings(document: document)
                                .padding(.top, 10)
                        }
                        .font(.callout)

                        ResultSection(document: document)
                    }
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
    /// PDF sits after the image formats; it isn't an image format itself.
    @Binding var isPDF: Bool

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(formats.map(Optional.some) + [nil], id: \.self) { format in
                let isSelected = format.map { !isPDF && selection == $0 } ?? isPDF
                Button {
                    if let format { selection = format }
                    isPDF = format == nil
                } label: {
                    Text(format?.displayName ?? "PDF")
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

// MARK: - PDF

/// Convert ▸ PDF: the opened image, as edited, saved as a PDF page.
private struct PDFExportSettings: View {
    @Bindable var document: ImageDocument

    var body: some View {
        let pages = document.pdfImages.count + 1
        Label(pages == 1 ? "1 page" : "\(pages) pages", systemImage: "doc.richtext")
            .font(.technical)
            .help("The picture as you see it, then any pages added in the PDF tool (⌘5).")
        PDFPageSizeSection(document: document)
        PDFQualitySection(document: document)
    }
}

// MARK: - Advanced

/// Quality, lossless repacking and smaller dimensions: everything that
/// trades size, kept out of the way until asked for.
private struct AdvancedSettings: View {
    @Bindable var document: ImageDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if document.target.hasLossyMode {
                QualityControl(quality: $document.quality, target: document.target)
            }
            if document.info?.format == document.target && document.target.canOptimizeLosslessly {
                Toggle("Smaller without loss", isOn: $document.optimize)
                    .toggleStyle(.switch)
                    .tint(Theme.ember)
                    .help("Repacks the \(document.target.displayName) data more tightly. Every pixel stays identical.")
            }
            DimensionsSection(document: document)
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

// MARK: - Dimensions

/// Fewer pixels: the biggest size saving there is. Always proportional
/// (nothing can be stretched) and never larger than the original.
private struct DimensionsSection: View {
    @Bindable var document: ImageDocument
    @State private var isOn = false

    private enum Choice: Hashable {
        case original
        case percent(Int)
        case longEdge(Int)
    }

    var body: some View {
        if let base = document.framedSize {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Change dimensions", isOn: Binding(
                    get: { isOn || document.geometry.resize != nil },
                    set: { on in
                        isOn = on
                        if !on { document.geometry.resize = nil }
                    }
                ))
                .toggleStyle(.switch)
                .tint(Theme.ember)
                .help("Fewer pixels make a much smaller file. Proportions stay the same; never larger than the original.")

                if isOn || document.geometry.resize != nil {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(options(for: base), id: \.choice) { option in
                            let size = size(for: option.choice, base: base)
                            TwoLineChip(title: option.title, subtitle: "\(size.width) × \(size.height)",
                                        isSelected: (document.geometry.resize ?? base) == size) {
                                document.geometry.resize = option.choice == .original ? nil : size
                            }
                        }
                    }
                }
            }
        }
    }

    private typealias Option = (choice: Choice, title: String)

    private func options(for base: PixelSize) -> [Option] {
        let longest = max(base.width, base.height)
        var options: [Option] = [(.original, "Original")]
        for percent in [75, 50, 25] {
            options.append((.percent(percent), "\(percent)%"))
        }
        for (edge, use) in [(3840, "4K"), (2048, "Web")] where edge < longest {
            options.append((.longEdge(edge), "\(edge) · \(use)"))
        }
        return options
    }

    private func size(for choice: Choice, base: PixelSize) -> PixelSize {
        switch choice {
        case .original: base
        case .percent(let percent): scaled(base, Double(percent) / 100)
        case .longEdge(let edge): scaled(base, Double(edge) / Double(max(base.width, base.height)))
        }
    }

    /// Same factor on both sides: the aspect ratio can't change.
    private func scaled(_ base: PixelSize, _ factor: Double) -> PixelSize {
        PixelSize(width: max(Int((Double(base.width) * factor).rounded()), 1),
                  height: max(Int((Double(base.height) * factor).rounded()), 1))
    }
}
