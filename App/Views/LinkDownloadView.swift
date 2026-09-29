import AppKit
import Downloader
import MediaModel
import SwiftUI

/// "Paste a YouTube link": on the drop screen and in the File ▸ Download
/// Audio from Link… sheet. Continuing opens the format page.
struct LinkDownloadField: View {
    @Bindable var download: LinkDownload

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("Paste a YouTube link", text: $download.text)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .onSubmit { download.lookUp() }
                Button("Continue") { download.lookUp() }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.ember)
                    .controlSize(.small)
                    .disabled(download.parsedLink == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))

            Group {
                if !download.text.isEmpty && download.parsedLink == nil {
                    Text("That doesn't look like a YouTube link.").foregroundStyle(.orange)
                } else {
                    Text("Choose audio (MP3, AAC, FLAC…) or video (up to 4K) on the next page. Only download what you have the right to use.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LinkDownloadSheet: View {
    let download: LinkDownload
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download Audio from Link").font(.headline)
            LinkDownloadField(download: download)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - The format page

/// The video (thumbnail, title, channel, length), the formats to choose
/// from, and the download itself.
struct LinkPage: View {
    @Bindable var download: LinkDownload
    let open: @MainActor (URL) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Back", systemImage: "chevron.left") { download.close() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text(download.kind == .video ? "Download Video" : "Download Audio").font(.headline)
                Spacer()
                Color.clear.frame(width: 50, height: 1)
            }
            .padding(.bottom, 18)

            switch download.stage {
            case .lookingUp:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Looking up the video…").foregroundStyle(.secondary)
                    Text("The first time also sets up the downloader (about 35 MB).").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            case .failed(let message) where download.info == nil:
                failure(message)
            default:
                if let info = download.info { content(info) }
            }
        }
        .padding(24)
        .frame(width: 560)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(_ info: LinkInfo) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                if let thumbnail = download.thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.white.opacity(0.06)
                    Image(systemName: "music.note").font(.title).foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title).font(.title3.weight(.semibold)).lineLimit(2)
                if let artist = info.artist { Text(artist).foregroundStyle(.secondary) }
                if let duration = info.duration {
                    Text(verbatim: TimeText.string(Int64(duration * 1000), rate: 1000, precise: false))
                        .font(.technicalSmall).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.bottom, 18)

        KindSwitch(kind: $download.kind)
            .disabled(download.isBusy)
            .padding(.bottom, 14)

        switch download.kind {
        case .audio:
            PanelSectionHeader("Save as")
                .padding(.bottom, 8)
            VStack(spacing: 6) {
                ForEach(LinkFormatOption.formats, id: \.self) { format in
                    FormatRow(download: download, format: format, sourceKbps: info.aacKbps)
                }
            }
            .disabled(download.isBusy)
        case .video:
            HStack {
                PanelSectionHeader("Quality")
                Toggle("Plays everywhere", isOn: $download.playsEverywhere)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                    .fixedSize()
                    .help("Only H.264, which every device and app plays. YouTube has it up to 1080p.")
            }
            .padding(.bottom, 8)
            if download.videoChoices.isEmpty {
                Text("This video has no stream macOS can save without re-encoding.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(download.videoChoices) { option in
                            VideoRow(download: download, option: option, isBest: option.id == download.defaultVideo?.id)
                        }
                    }
                }
                .frame(maxHeight: 290)
                .disabled(download.isBusy)
            }
            Text(videoNote(info))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }

        footer
            .padding(.top, 18)
    }

    @ViewBuilder
    private var footer: some View {
        switch download.stage {
        case .downloading(let phase):
            progress(label(phase), fraction: fraction(phase))
        case .saving(let fraction):
            progress("Saving as \(LinkFormatOption.title(download.format))…", fraction: fraction)
        case .done(let url):
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Label("Saved “\(url.lastPathComponent)” to Downloads", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .lineLimit(2)
                    Spacer()
                    DismissButton { download.readyForAnother() }
                        .help("Back to the Download button, to save another format or quality")
                }
                HStack {
                    if url.pathExtension == "mp4" {
                        Button("Play") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.glassProminent)
                            .tint(Theme.ember)
                    } else {
                        Button("Open in Editor") {
                            Task {
                                await open(url)
                                download.close()
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.ember)
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.glass)
                    Spacer()
                    Button("Save Another Format") { download.readyForAnother() }
                        .buttonStyle(.link)
                        .tint(Theme.ember)
                    Button("New Link") { download.close() }
                        .buttonStyle(.link)
                        .tint(Theme.ember)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                downloadButton(title: "Try Again")
            }
        default:
            downloadButton(title: download.kind == .video
                           ? "Download \(download.selectedVideo.map { [$0.label, $0.nickname, $0.isConverted ? "H.264" : nil].compactMap { $0 }.joined(separator: " · ") } ?? "Video")"
                           : "Download \(LinkFormatOption.title(download.format))")
                .disabled(download.kind == .video && download.selectedVideo == nil)
        }
    }

    private func videoNote(_ info: LinkInfo) -> String {
        if download.selectedVideo?.isConverted == true {
            return "YouTube only has H.264 up to 1080p. This size is converted from YouTube's AV1 on your Mac with the hardware encoder at a high bit rate, so it plays everywhere. It's a second encode (a small loss), a larger file, and takes a few minutes. The sound is copied as it is."
        }
        var note = "Saved as MP4 exactly as YouTube streams it: picture and sound are joined, nothing is re-encoded."
        if !download.playsEverywhere, download.selectedVideo?.isH264 == false {
            note += " AV1 plays on Macs with M3 or newer, iPhone 15 Pro and later, and modern browsers; older devices may not play it, so switch on Plays everywhere for H.264."
        }
        if let vp9 = info.vp9OnlyHeight {
            note += " YouTube also has \(vp9)p, but only as VP9, which macOS can't play."
        }
        return note
    }

    private func downloadButton(title: String) -> some View {
        Button {
            download.download()
        } label: {
            Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.ember)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    private func progress(_ label: String, fraction: Double?) -> some View {
        HStack(spacing: 12) {
            if let fraction {
                ProgressView(value: fraction) { Text(label).font(.callout) }.tint(Theme.ember)
            } else {
                ProgressView().controlSize(.small)
                Text(label).font(.callout)
                Spacer()
            }
            Button("Cancel", systemImage: "xmark.circle.fill") { download.cancel() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
    }

    private func label(_ phase: LinkDownloadPhase) -> String {
        switch phase {
        case .settingUp: "Setting up the downloader…"
        case .updating: "Updating the downloader and trying again…"
        case .downloading(let fraction): "Downloading \(Int(fraction * 100))%"
        case .finishing: download.kind == .video ? "Joining picture and sound…" : "Finishing the download…"
        case .converting(let fraction): "Converting to H.264 \(Int(fraction * 100))%"
        }
    }

    private func fraction(_ phase: LinkDownloadPhase) -> Double? {
        switch phase {
        case .downloading(let fraction), .converting(let fraction): fraction
        default: nil
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { download.lookUp() }.buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}

/// One format in the list: name, quality, what it means.
private struct FormatRow: View {
    @Bindable var download: LinkDownload
    let format: AudioFormat
    let sourceKbps: Int?

    private var isSelected: Bool { download.format == format }

    var body: some View {
        Button {
            download.format = format
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Theme.ember : .secondary)
                    .font(.system(size: 15))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(LinkFormatOption.title(format)).font(.system(.callout, design: .monospaced, weight: .semibold))
                        Text(quality).font(.technicalSmall).foregroundStyle(.secondary)
                        if format == .aac {
                            Text("Best quality")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.green.opacity(0.15), in: Capsule())
                        }
                    }
                    if isSelected {
                        Text(LinkFormatOption.detail(format, sourceKbps: sourceKbps))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if format == .mp3 {
                            Picker("Bit rate", selection: $download.mp3BitRate) {
                                ForEach(AudioRequest.bitRates.reversed(), id: \.self) { Text("\($0) kbit/s").tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .controlSize(.small)
                            .padding(.top, 4)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected ? Theme.ember.opacity(0.12) : .white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isSelected ? Theme.ember.opacity(0.6) : .white.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var quality: String {
        switch format {
        case .aac: sourceKbps.map { "\($0) kbit/s · as streamed" } ?? "as streamed"
        case .mp3: "\(download.mp3BitRate) kbit/s"
        case .flac, .alac: "lossless"
        case .wav, .aiff: "uncompressed"
        }
    }
}

/// One video quality: resolution, codec, size.
private struct VideoRow: View {
    @Bindable var download: LinkDownload
    let option: VideoOption
    let isBest: Bool

    private var isSelected: Bool { download.videoFormat == option.id }

    var body: some View {
        Button {
            download.videoFormat = option.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Theme.ember : .secondary)
                    .font(.system(size: 15))
                Text(option.label).font(.system(.callout, design: .monospaced, weight: .semibold))
                    .frame(width: 70, alignment: .leading)
                if let nickname = option.nickname {
                    Text(nickname).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                if option.isHDR { badge("HDR", .purple) }
                if isBest { badge(download.videoChoices.first?.isConverted == true ? "Best as streamed" : "Highest", .green) }
                if option.isConverted {
                    badge("Converted", .orange)
                        .help("YouTube has no H.264 this size: DEX converts its AV1 on your Mac. Takes a few minutes; loses a little.")
                }
                Spacer()
                Text(option.codec).font(.technicalSmall).foregroundStyle(.secondary)
                if let bytes = option.bytes {
                    // Converted sizes are the encoder's ceiling; easy scenes use less.
                    Text(verbatim: (option.isConverted ? "≤ " : "≈ ") + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(.technicalSmall)
                        .foregroundStyle(.secondary)
                        .frame(width: 78, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected ? Theme.ember.opacity(0.12) : .white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isSelected ? Theme.ember.opacity(0.6) : .white.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String, _ colour: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(colour)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(colour.opacity(0.15), in: Capsule())
    }
}

/// Audio | Video, with the chosen side unmistakably filled in ember.
private struct KindSwitch: View {
    @Binding var kind: LinkDownload.Kind

    var body: some View {
        HStack(spacing: 4) {
            side(.audio, "Audio", "waveform")
            side(.video, "Video", "film")
        }
        .padding(4)
        .background(.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
        .animation(.spring(duration: 0.25), value: kind)
    }

    private func side(_ value: LinkDownload.Kind, _ title: String, _ symbol: String) -> some View {
        let isSelected = kind == value
        return Button {
            kind = value
        } label: {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(isSelected ? .white : .secondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(Capsule().fill(isSelected ? Theme.ember : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
