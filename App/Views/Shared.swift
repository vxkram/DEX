import MediaModel
import SwiftUI

/// The live quality verdict for the current settings, shown by every tool.
struct ResultSection: View {
    let document: ImageDocument

    var body: some View {
        if let result = document.planResult {
            VStack(alignment: .leading, spacing: 10) {
                PanelSectionHeader("Result")
                switch result {
                case .success(let plan):
                    let size = plan.outputDisplaySize
                    Text(verbatim: "Saves as \(plan.request.target.displayName) · \(size.width) × \(size.height)")
                        .font(.technical)
                        .help("Change the format in Convert (⌘1).")
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

            Button {
                document.export()
            } label: {
                Text(document.tool != .convert ? "Choose Format & Export →"
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
