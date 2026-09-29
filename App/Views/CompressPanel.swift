import MediaModel
import SwiftUI

/// Make the file smaller: losslessly by default, or with a quality slider.
struct CompressPanel: View {
    @Bindable var document: ImageDocument

    private enum Mode: Hashable { case lossless, smaller }

    private var mode: Binding<Mode> {
        Binding(
            get: { document.quality == .maximum ? .lossless : .smaller },
            set: { mode in
                switch mode {
                case .lossless:
                    document.quality = .maximum
                    document.optimize = true
                case .smaller:
                    document.optimize = false
                    if document.quality == .maximum { document.quality = .custom(0.8) }
                }
            }
        )
    }

    var body: some View {
        ToolPanelBody(document: document) {
            SizeComparison(document: document)

            VStack(spacing: 10) {
                PanelSectionHeader("Method")
                Picker("Method", selection: mode) {
                    Text("Lossless").tag(Mode.lossless)
                    Text("Smaller file").tag(Mode.smaller)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
            }

            switch mode.wrappedValue {
            case .lossless:
                Explanation(losslessExplanation)
            case .smaller:
                if document.target.hasLossyMode {
                    CompressionQuality(quality: $document.quality)
                    Explanation("Lower quality removes detail you're least likely to notice. Compare in the preview at 100% before exporting.")
                } else {
                    Explanation("\(document.target.displayName) is always lossless, so it can't trade quality for size. Choose a format that can:")
                    HStack(spacing: 8) {
                        ForEach([ImageFormat.jpeg, .webp, .heic].filter(document.writableFormats.contains), id: \.self) { format in
                            Chip(title: format.displayName, isSelected: false) { document.target = format }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Remove all metadata", isOn: Binding(
                    get: { document.metadata == .removeAll },
                    set: { document.metadata = $0 ? .removeAll : .removeLocation }
                ))
                .toggleStyle(.switch)
                .tint(Theme.ember)
                .font(.callout)
                Explanation("Camera details, dates and location. Saves a few KB; orientation and colour are kept.")
            }
        }
        .onAppear {
            // Opening Compress means "make it smaller": start lossless.
            if document.quality == .maximum { document.optimize = true }
        }
    }

    private var losslessExplanation: String {
        let same = document.info?.format == document.target
        switch (document.target, same) {
        case (.jpeg, true):
            return "Repacks the JPEG's compressed data more efficiently. Every pixel stays identical."
        case (.png, true), (.tiff, true):
            return "Re-compresses the \(document.target.displayName) more efficiently. Every pixel stays identical."
        case (_, true):
            return "\(document.target.displayName) has no lossless way to get smaller. Only removing metadata saves space; use Smaller file for more."
        default:
            return "Converting to \(document.target.displayName). Its size is shown above; switch to Smaller file to trade quality for size."
        }
    }
}

/// Original vs. measured result, side by side.
private struct SizeComparison: View {
    let document: ImageDocument

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Column(title: "Original", bytes: document.info?.fileSize, highlight: false)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            Column(title: "Result", bytes: document.currentEstimate?.bytes, highlight: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct Column: View {
        let title: String
        let bytes: Int64?
        let highlight: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                PanelSectionHeader(title)
                if let bytes {
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(.system(.title2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(highlight ? Theme.ember : .primary)
                } else {
                    ProgressView().controlSize(.small).frame(height: 28)
                }
            }
        }
    }
}

private struct CompressionQuality: View {
    @Binding var quality: QualityPreference

    var body: some View {
        let value = Binding<Double>(
            get: { quality.lossyValue },
            set: { quality = .custom(min($0, 0.94)) }
        )
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Quality")
                Spacer()
                Text(verbatim: "\(Int((value.wrappedValue * 100).rounded()))")
                    .font(.technical)
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0.3...0.94) {
                Text("Quality")
            } minimumValueLabel: {
                Text("Smaller").font(.caption2)
            } maximumValueLabel: {
                Text("Better").font(.caption2)
            }
            .tint(Theme.ember)
        }
    }
}
