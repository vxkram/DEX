import MediaModel
import SwiftUI

/// File facts, conversion settings and the honest quality verdict.
struct InspectorView: View {
    @Bindable var document: ImageDocument
    @State private var showsAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let info = document.info {
                    FileFactsSection(info: info)
                }

                Section("Convert to") {
                    FormatGrid(formats: document.writableFormats, selection: $document.target)
                }

                Section("Metadata") {
                    Picker("Metadata", selection: $document.metadata) {
                        Text("Keep all").tag(MetadataPolicy.keepAll)
                        Text("Remove location").tag(MetadataPolicy.removeLocation)
                        Text("Remove all").tag(MetadataPolicy.removeAll)
                    }
                    .labelsHidden()
                }

                if document.plan?.lossyQuality != nil {
                    Section {
                        DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                            QualityControl(quality: $document.quality)
                        }
                    }
                }

                if let result = document.planResult {
                    Section("Result") {
                        switch result {
                        case .success(let plan): PlanSummary(plan: plan, document: document)
                        case .failure(let error): Label(String(describing: error), systemImage: "xmark.octagon").foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            ExportBar(document: document)
        }
    }
}

// MARK: - File facts

private struct FileFactsSection: View {
    let info: MediaInfo

    var body: some View {
        Section("File") {
            LabeledContent("Format", value: info.format?.displayName ?? info.typeIdentifier)
            LabeledContent("Dimensions", value: "\(info.displayWidth) × \(info.displayHeight)")
            LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file))
            LabeledContent("Colour", value: colour)
            LabeledContent("HDR", value: info.hasHDRGainMap ? "Gain map" : "No")
            if info.isAnimated {
                LabeledContent("Frames", value: "\(info.frameCount)")
            }
            LabeledContent("Location") {
                if info.hasGPS {
                    Label("Present", systemImage: "location.fill").foregroundStyle(.orange)
                } else {
                    Text("None")
                }
            }
        }
    }

    private var colour: String {
        let depth = info.bitsPerComponent.map { "\($0)-bit" } ?? ""
        let profile = info.colorProfile ?? info.colorModel ?? "Unknown"
        return [profile, depth, info.hasAlpha ? "alpha" : ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

// MARK: - Format grid

private struct FormatGrid: View {
    let formats: [ImageFormat]
    @Binding var selection: ImageFormat

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(formats, id: \.self) { format in
                Button {
                    selection = format
                } label: {
                    Text(format.displayName)
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .tint(selection == format ? .dexAccent : Color.secondary.opacity(0.18))
                .foregroundStyle(selection == format ? .white : .primary)
                .accessibilityAddTraits(selection == format ? .isSelected : [])
            }
        }
        .padding(.vertical, 2)
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
                Text(quality == .maximum ? "Maximum (95)" : "\(Int((value.wrappedValue * 100).rounded()))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0.4...QualityPreference.maximumLossyQuality)
            Text("Lower quality makes smaller files but loses more detail.")
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
        ForEach(Array(plan.notes.enumerated()), id: \.offset) { _, note in
            Label {
                Text(note.description).font(.callout)
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
        if let alternative = plan.losslessAlternative {
            Button("Use \(alternative.displayName) instead: lossless, larger file") {
                document.target = alternative
            }
            .buttonStyle(.link)
        }
    }
}

struct VerdictBadge: View {
    let verdict: QualityVerdict

    var body: some View {
        Label(verdict.label, systemImage: symbol)
            .font(.headline)
            .foregroundStyle(colour)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(colour.opacity(0.14), in: Capsule())
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

private struct ExportBar: View {
    let document: ImageDocument

    var body: some View {
        VStack(spacing: 10) {
            switch document.exportState {
            case .running(let fraction):
                HStack {
                    ProgressView(value: fraction)
                    Button("Cancel", systemImage: "xmark.circle.fill") { document.cancelExport() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            case .saved(let url):
                HStack {
                    Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") { document.revealInFinder(url) }
                        .buttonStyle(.link)
                }
                .font(.callout)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            case .idle:
                EmptyView()
            }

            Button {
                document.requestExport()
            } label: {
                Text("Export…")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!document.canExport)
            .help("Export (⌘E)")
        }
        .padding(16)
    }
}
