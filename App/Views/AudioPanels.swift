import AppKit
import AudioEngine
import MediaModel
import SwiftUI

/// A tool panel's scrolling content above the shared Export footer.
private struct AudioPanelBody<Content: View>: View {
    let audio: AudioDocument
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    content
                    AudioResultSection(audio: audio)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
            AudioExportFooter(audio: audio)
        }
    }
}

// MARK: - Trim

struct TrimPanel: View {
    let audio: AudioDocument

    var body: some View {
        AudioPanelBody(audio: audio) {
            VStack(spacing: 10) {
                PanelSectionHeader("Keep")
                TimeRow(label: "Start", frame: audio.kept.start, rate: audio.sampleRate, key: "I",
                        set: audio.setTrimStart, useLabel: "Set to playhead") { audio.setTrimStart(audio.playhead) }
                TimeRow(label: "End", frame: audio.kept.end, rate: audio.sampleRate, key: "O",
                        set: audio.setTrimEnd, useLabel: "Set to playhead") { audio.setTrimEnd(audio.playhead) }
                HStack {
                    Text("Length").foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: TimeText.string(audio.kept.length, rate: audio.sampleRate)).font(.technical)
                }
                .font(.callout)
                Explanation("I and O set start and end at the playhead.")
            }

            if audio.edit.trim != nil {
                Button("Reset trim", systemImage: "arrow.counterclockwise") { audio.resetTrim() }
                    .buttonStyle(.link)
                    .tint(Theme.ember)
                    .font(.callout)
            }
        }
    }
}

// MARK: - Convert

struct AudioConvertPanel: View {
    @Bindable var audio: AudioDocument

    var body: some View {
        AudioPanelBody(audio: audio) {
            VStack(spacing: 10) {
                PanelSectionHeader("Format")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(AudioFormat.allCases, id: \.self) { format in
                        FormatTile(format: format, isSelected: audio.target == format, isOriginal: audio.info?.format == format) {
                            audio.target = format
                        }
                    }
                }
            }

            if !audio.target.isLossless {
                VStack(spacing: 10) {
                    PanelSectionHeader("Bit rate")
                    Picker("Bit rate", selection: $audio.bitRate) {
                        Text("Best").tag(Int?.none)
                        ForEach(AudioRequest.bitRates.reversed(), id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help(audio.info?.format == audio.target
                          ? "Best keeps the original \(audio.target.displayName) data untouched where it can. A number re-encodes at that rate (kbit/s)."
                          : "Best is \(AudioRequest.maximumBitRate) kbit/s, the highest \(audio.target.displayName) offers.")
                }
            }
        }
    }
}

private struct FormatTile: View {
    let format: AudioFormat
    let isSelected: Bool
    let isOriginal: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(format.displayName)
                    .font(.system(.callout, design: .monospaced, weight: .semibold))
                Text(format.isLossless ? "Lossless" : "Lossy")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .foregroundStyle(isSelected ? .white : .primary)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected ? Theme.ember : .white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(isSelected ? 0 : 0.08)))
            .overlay(alignment: .topTrailing) {
                if isOriginal {
                    Circle().fill(isSelected ? .white : Theme.ember).frame(width: 5, height: 5).padding(6)
                        .help("The file's current format")
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(format.summary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Info

struct AudioInfoPanel: View {
    let audio: AudioDocument

    var body: some View {
        ScrollView {
            if let info = audio.info {
                VStack(spacing: 0) {
                    AudioFact("Codec", info.codecName)
                    AudioFact("Duration", TimeText.string(info.frames, rate: info.sampleRate))
                    AudioFact("Sample rate", AudioFacts.rate(info.sampleRate))
                    AudioFact("Channels", AudioFacts.channels(info.channels))
                    AudioFact("Bit depth", info.isFloat ? "\(info.bitDepth ?? 32)-bit float" : info.bitDepth.map { "\($0)-bit" } ?? "— (lossy)")
                    if let bitRate = info.bitRate { AudioFact("Bit rate", "\(bitRate / 1000) kbit/s") }
                    AudioFact("Samples", info.frames.formatted())
                    AudioFact("File size", ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file))
                    AudioFact("Tags", info.hasTags ? "Yes" : "None")
                    if let peak = info.peak {
                        let db = 20 * log10(Double(max(peak, 1e-9)))
                        AudioFact("Peak", String(format: "%.1f dBFS", db), highlight: peak > 1)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .scrollIndicators(.never)
    }
}

private struct AudioFact: View {
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
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(verbatim: value)
                .font(.technical)
                .foregroundStyle(highlight ? .orange : .primary)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }
}

// MARK: - Result

struct AudioResultSection: View {
    let audio: AudioDocument

    var body: some View {
        if let result = audio.planResult {
            VStack(alignment: .leading, spacing: 10) {
                PanelSectionHeader("Result")
                switch result {
                case .success(let plan):
                    Text(verbatim: summary(plan))
                        .font(.technical)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("Change the format in Convert (⌘2).")
                    AudioEstimateLine(audio: audio)
                    VerdictBadge(verdict: plan.verdict)
                    NoteList(notes: plan.notes)
                    if let alternative = plan.losslessAlternative {
                        Button {
                            audio.target = alternative
                        } label: {
                            Label("Use \(alternative.displayName) instead: lossless, larger", systemImage: "arrow.uturn.right")
                                .font(.callout)
                        }
                        .buttonStyle(.link)
                        .tint(Theme.ember)
                    }
                case .failure(let error):
                    Label(String(describing: error), systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
    }

    private func summary(_ plan: AudioPlan) -> String {
        let what = plan.request.target.displayName
        var details = [AudioFacts.rate(plan.sampleRate), AudioFacts.channels(plan.channels)]
        if plan.isFloat { details.insert("32-bit float", at: 0) }
        else if let bits = plan.bitDepth, plan.request.target.isLossless { details.insert("\(bits)-bit", at: 0) }
        else if let kbps = plan.bitRate { details.insert("\(kbps) kbit/s", at: 0) }
        return "Saves as \(what) · " + details.joined(separator: " · ")
            + "\nLength " + TimeText.string(audio.outputLength, rate: audio.sampleRate)
    }
}

private struct NoteList: View {
    let notes: [AudioNote]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                Label {
                    Text(note.description).font(.callout).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: note.isLoss ? "minus.circle.fill" : "info.circle")
                        .foregroundStyle(note.isLoss ? .orange : .secondary)
                }
            }
        }
    }
}

private struct AudioEstimateLine: View {
    let audio: AudioDocument

    var body: some View {
        HStack(spacing: 6) {
            if let bytes = audio.currentEstimate {
                Image(systemName: "doc").foregroundStyle(.secondary)
                Text(verbatim: "≈ " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.technical)
                if let original = audio.info?.fileSize, original > 0 {
                    let change = Double(bytes - original) / Double(original)
                    Text(verbatim: change.magnitude < 0.005 ? "same size"
                         : "\(Int((change.magnitude * 100).rounded()))% \(change < 0 ? "smaller" : "larger")")
                        .font(.technicalSmall)
                        .foregroundStyle(change > 0.005 ? .orange : change < -0.005 ? .green : .secondary)
                }
            } else {
                ProgressView().controlSize(.mini)
                Text("Measuring size…").font(.technicalSmall).foregroundStyle(.secondary)
            }
        }
        .help("Worked out from the format, or measured by encoding a sample.")
    }
}

// MARK: - Export footer

struct AudioExportFooter: View {
    let audio: AudioDocument

    var body: some View {
        VStack(spacing: 10) {
            switch audio.exportState {
            case .running(let fraction):
                HStack {
                    ProgressView(value: fraction).tint(Theme.ember)
                    Button("Cancel", systemImage: "xmark.circle.fill") { audio.cancelExport() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            case .saved(let url):
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(url.lastPathComponent).font(.technicalSmall).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.link)
                        .tint(Theme.ember)
                    DismissButton { audio.dismissExportStatus() }
                }
                .font(.callout)
            case .failed(let message):
                HStack(alignment: .top) {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    DismissButton { audio.dismissExportStatus() }
                }
            case .idle:
                EmptyView()
            }

            Button {
                audio.export()
            } label: {
                Text(title)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.ember)
            .controlSize(.large)
            .disabled(!audio.canExport)
            .help("Export (⌘E)")
        }
        .padding(16)
    }

    private var title: String {
        if audio.tool != .convert { return "Choose Format & Export →" }
        return audio.plan?.verdict == .lossy ? "Export with Loss…" : "Export…"
    }
}

// MARK: - Time entry

/// A labelled time field ("1:23.456") with an optional playhead button.
private struct TimeRow: View {
    let label: String
    let frame: Int64
    let rate: Double
    let key: String?
    let set: (Int64) -> Void
    var useLabel: String?
    var use: (() -> Void)?

    init(label: String, frame: Int64, rate: Double, key: String?, set: @escaping (Int64) -> Void,
         useLabel: String? = nil, use: (() -> Void)? = nil) {
        self.label = label
        self.frame = frame
        self.rate = rate
        self.key = key
        self.set = set
        self.useLabel = useLabel
        self.use = use
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            TimeField(frame: frame, rate: rate, set: set)
            if let use {
                Button(useLabel ?? "Use playhead", systemImage: "playhead.and.arrow.forward", action: use)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help((useLabel ?? "Use playhead") + (key.map { " (\($0))" } ?? ""))
            }
        }
        .font(.callout)
    }
}

private struct TimeField: View {
    let frame: Int64
    let rate: Double
    let set: (Int64) -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("0:00.000", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.technical)
            .multilineTextAlignment(.trailing)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { _, focused in if !focused { commit() } }
            .onChange(of: frame, initial: true) { _, frame in text = TimeText.string(frame, rate: rate) }
    }

    private func commit() {
        guard let value = TimeText.frame(from: text, rate: rate) else {
            text = TimeText.string(frame, rate: rate)
            return
        }
        text = TimeText.string(value, rate: rate)
        set(value)
    }
}
