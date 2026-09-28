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

                    if document.plan?.lossyQuality != nil {
                        DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                            QualityControl(quality: $document.quality)
                                .padding(.top, 10)
                        }
                        .font(.callout)
                    }

                    if let result = document.planResult {
                        VStack(alignment: .leading, spacing: 10) {
                            PanelSectionHeader("Result")
                            switch result {
                            case .success(let plan):
                                PlanSummary(plan: plan, document: document)
                            case .failure(let error):
                                Label(String(describing: error), systemImage: "xmark.octagon")
                                    .foregroundStyle(.red)
                                    .font(.callout)
                            }
                        }
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

    var body: some View {
        let value = Binding<Double>(
            get: { quality.lossyValue },
            set: { quality = $0 >= QualityPreference.maximumLossyQuality ? .maximum : .custom($0) }
        )
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Quality")
                Spacer()
                Text(quality == .maximum ? "Max · 95" : "\(Int((value.wrappedValue * 100).rounded()))")
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

// MARK: - Verdict

private struct PlanSummary: View {
    let plan: ConversionPlan
    let document: ImageDocument

    var body: some View {
        VerdictBadge(verdict: plan.verdict)

        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(plan.notes.enumerated()), id: \.offset) { _, note in
                Label {
                    Text(note.description)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: note.isLoss ? "minus.circle.fill" : "info.circle")
                        .foregroundStyle(note.isLoss ? .orange : .secondary)
                }
            }
            if plan.notes.isEmpty && plan.verdict == .noReencode {
                Text("The image data is copied exactly as it is.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }

        if let alternative = plan.losslessAlternative {
            Button {
                document.target = alternative
            } label: {
                Label("Use \(alternative.displayName) instead: lossless, larger", systemImage: "arrow.uturn.right")
                    .font(.callout)
            }
            .buttonStyle(.link)
            .tint(Theme.ember)
        }
    }
}

struct VerdictBadge: View {
    let verdict: QualityVerdict

    var body: some View {
        Label(verdict.label, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(colour)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(colour.opacity(0.15), in: Capsule())
    }

    private var symbol: String {
        switch verdict {
        case .noReencode: "checkmark.seal.fill"
        case .lossless: "checkmark.circle.fill"
        case .lossy: "exclamationmark.triangle.fill"
        }
    }

    private var colour: Color {
        switch verdict {
        case .noReencode: .green
        case .lossless: .teal
        case .lossy: .orange
        }
    }
}

// MARK: - Export

private struct ExportFooter: View {
    let document: ImageDocument

    var body: some View {
        VStack(spacing: 10) {
            switch document.exportState {
            case .running(let fraction):
                HStack {
                    ProgressView(value: fraction).tint(Theme.ember)
                    Button("Cancel", systemImage: "xmark.circle.fill") { document.cancelExport() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            case .saved(let url):
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(url.lastPathComponent)
                        .font(.technicalSmall)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") { document.revealInFinder(url) }
                        .buttonStyle(.link)
                        .tint(Theme.ember)
                }
                .font(.callout)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                EmptyView()
            }

            Button {
                document.presentSavePanel()
            } label: {
                Text(document.plan?.verdict == .lossy ? "Export with Loss…" : "Export…")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.ember)
            .controlSize(.large)
            .disabled(!document.canExport)
            .help("Export (⌘E)")
        }
        .padding(16)
    }
}
