import MediaModel
import SwiftUI

/// The live quality verdict for the current settings, shown by every tool:
/// the verdict and size at a glance, the reasons one click away.
struct ResultSection: View {
    let document: ImageDocument

    var body: some View {
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
}

/// A tool panel's scrolling content above the shared Export footer.
struct ToolPanelBody<Content: View>: View {
    let document: ImageDocument
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    content
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

// MARK: - Verdict

struct PlanSummary: View {
    let plan: ConversionPlan
    let document: ImageDocument
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 10) {
            VerdictBadge(verdict: plan.verdict)
            Spacer(minLength: 0)
        }
        EstimateLine(document: document)

        if !plan.notes.isEmpty {
            DisclosureGroup(isExpanded: $showsDetails) {
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
                }
                .padding(.top, 6)
            } label: {
                let losses = plan.notes.filter(\.isLoss).count
                Text(losses > 0 ? "What changes (\(losses) loss\(losses == 1 ? "" : "es"))" : "What changes")
                    .font(.callout)
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

struct ExportFooter: View {
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
                    DismissButton { document.dismissExportStatus() }
                }
                .font(.callout)
            case .failed(let message):
                HStack(alignment: .top) {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    DismissButton { document.dismissExportStatus() }
                }
            case .idle:
                EmptyView()
            }

            OutputSizeLine(document: document)

            Button {
                document.export()
            } label: {
                Text(document.tool != .convert ? "Choose Format & Export →"
                     : document.exportAsPDF ? "Export PDF…"
                     : document.plan?.verdict == .lossy ? "Export with Loss…" : "Export…")
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

/// Exactly what will be saved, in pixels, right above the Export button.
struct OutputSizeLine: View {
    let document: ImageDocument

    var body: some View {
        if let plan = document.plan {
            let size = plan.outputDisplaySize
            HStack(alignment: .firstTextBaseline) {
                Text(document.exportAsPDF ? "PDF page from" : "Saves at")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: "\(size.width) × \(size.height) px")
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                    .foregroundStyle(Theme.ember)
                if !document.exportAsPDF {
                    Text(verbatim: plan.request.target.displayName)
                        .font(.technicalSmall)
                        .foregroundStyle(.secondary)
                }
            }
            .help("The exported file is exactly this many pixels wide and high.")
        }
    }
}

/// Small ✕ that clears a status message.
struct DismissButton: View {
    let action: () -> Void

    var body: some View {
        Button("Dismiss", systemImage: "xmark", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .font(.caption.weight(.semibold))
            .help("Dismiss")
    }
}

/// "≈ 2.4 MB · 12% smaller": the measured size of the export.
struct EstimateLine: View {
    let document: ImageDocument

    var body: some View {
        HStack(spacing: 6) {
            if let estimate = document.currentEstimate, let bytes = estimate.bytes {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                Text(verbatim: "≈ " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.technical)
                if let original = document.info?.fileSize, original > 0 {
                    let change = Double(bytes - original) / Double(original)
                    Text(verbatim: change.magnitude < 0.005 ? "same size"
                         : "\(Int((change.magnitude * 100).rounded()))% \(change < 0 ? "smaller" : "larger")")
                        .font(.technicalSmall)
                        .foregroundStyle(change > 0.005 ? .orange : change < -0.005 ? .green : .secondary)
                    if let reason = SizeIncreaseReason(document: document) {
                        WhyButton(reason: reason, document: document)
                    }
                }
            } else if let failure = document.currentEstimate?.failure {
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                Text("Size unknown").font(.technicalSmall).foregroundStyle(.secondary)
                    .help(failure)
            } else {
                ProgressView().controlSize(.mini)
                Text("Measuring size…")
                    .font(.technicalSmall)
                    .foregroundStyle(.secondary)
            }
        }
        .help("Measured by running the real export in the background.")
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

/// "Why?" → a popover with the reason and the fix.
struct WhyButton: View {
    let reason: SizeIncreaseReason
    let document: ImageDocument
    @State private var isShowingReason = false

    var body: some View {
        Button("Why?") { isShowingReason = true }
            .buttonStyle(.link)
            .tint(Theme.ember)
            .font(.caption.weight(.semibold))
            .focusable(false)
            .popover(isPresented: $isShowingReason, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(reason.explanation)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if let fix = reason.fix {
                        Button(fix.title) {
                            fix.apply(document)
                            isShowingReason = false
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.ember)
                    }
                }
                .padding(14)
                .frame(width: 280)
            }
    }
}

@MainActor
struct SizeIncreaseReason {
    struct Fix {
        let title: String
        let apply: @MainActor (ImageDocument) -> Void
    }

    let explanation: String
    let fix: Fix?
    let percent: Int

    init?(document: ImageDocument) {
        guard let info = document.info, let source = info.format, let plan = document.plan,
              let bytes = document.currentEstimate?.bytes, bytes > info.fileSize + info.fileSize / 50  // > 2 % larger
        else { return nil }
        let target = plan.request.target
        let percent = Int((Double(bytes - info.fileSize) / Double(info.fileSize) * 100).rounded())
        self.percent = percent
        let keepFormat: ImageFormat? = document.writableFormats.contains(source) ? source : (source == .heif ? .heic : nil)
        let keep = keepFormat.flatMap { format in
            format == target ? nil : Fix(title: "Keep it as \(format.displayName)") { $0.target = format }
        }
        let efficient: Set<ImageFormat> = [.heic, .heif, .avif, .webp]

        if plan.request.composition.map({ !$0.isEmpty }) ?? false {
            explanation = "Several images are combined into one, so there is simply more picture to store."
            fix = nil
        } else if target != source && target.supportsLossless && plan.lossyQuality == nil {
            explanation = "\(target.displayName) stores every pixel exactly (lossless), which takes far more space than \(source.displayName)'s compression. It won't look better than the original."
            fix = keep
        } else if target != source && efficient.contains(source) && !efficient.contains(target) {
            explanation = "\(source.displayName) is a newer format that compresses about twice as well as \(target.displayName), so the same picture needs more bytes."
            fix = keep
        } else if target != source {
            explanation = "\(target.displayName) is less efficient than \(source.displayName) for this image."
            fix = keep
        } else if let quality = plan.lossyQuality {
            explanation = "The original was saved at a lower quality than \(Int(quality * 100)). Re-encoding can't restore detail, so lower the quality for a smaller file."
            fix = nil
        } else {
            explanation = "Re-encoding produced a slightly larger file than the original."
            fix = nil
        }
    }
}
