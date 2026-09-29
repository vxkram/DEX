import AppKit
import MediaModel
import SwiftUI

/// The top half of the audio stage: cover art, title, artist and album,
/// all editable and saved into MP3, M4A and FLAC exports.
struct ArtworkHeader: View {
    @Bindable var audio: AudioDocument
    @State private var isTargeted = false

    var body: some View {
        GeometryReader { geometry in
            let side = max(min(geometry.size.height, geometry.size.width * 0.42), 60)
            HStack(alignment: .center, spacing: 22) {
                artwork(side: side)
                VStack(alignment: .leading, spacing: 6) {
                    TagField(placeholder: "Title", text: tag(\.title), font: .system(size: 22, weight: .bold))
                        .help(audio.tags.title ?? "")
                    TagField(placeholder: "Artist", text: tag(\.artist), font: .system(size: 16, weight: .medium))
                    TagField(placeholder: "Album", text: tag(\.album), font: .system(size: 14))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button(audio.tags.artwork == nil ? "Add Artwork…" : "Replace Artwork…", systemImage: "photo") {
                            audio.presentArtworkPanel()
                        }
                        .buttonStyle(.glass)
                        if audio.tags.artwork != nil {
                            Button("Remove", systemImage: "trash") { audio.removeArtwork() }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 8)
                    Text(audio.target.storesTags
                         ? "Saved with the \(audio.target.displayName) export."
                         : "\(audio.target.displayName) files don't keep artwork or tags; FLAC, ALAC, AAC and MP3 do.")
                        .font(.caption)
                        .foregroundStyle(audio.target.storesTags ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func tag(_ key: WritableKeyPath<AudioTags, String?>) -> Binding<String> {
        Binding(
            get: { audio.tags[keyPath: key] ?? "" },
            set: { audio.tags[keyPath: key] = $0.isEmpty ? nil : $0 }
        )
    }

    private func artwork(side: CGFloat) -> some View {
        ZStack {
            if let image = audio.artworkImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
            } else {
                LinearGradient(colors: [Theme.ember.opacity(0.35), .black.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 8) {
                    Image(systemName: "music.note").font(.system(size: 34, weight: .light))
                    Text("Add artwork").font(.caption.weight(.medium))
                }
                .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isTargeted ? Theme.ember : .white.opacity(0.1), style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [6, 4] : []))
        }
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            endTextEditing()
            audio.presentArtworkPanel()
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            audio.setArtwork(from: url)
            return true
        } isTargeted: { isTargeted = $0 }
        .help("Click or drop an image to set the cover art")
    }
}

/// A borderless text field that looks like a label until clicked.
private struct TagField: View {
    let placeholder: String
    @Binding var text: String
    let font: Font

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .lineLimit(1)
            // Return or Escape finishes editing, like Finder's rename.
            .onSubmit { endTextEditing() }
            .onExitCommand { endTextEditing() }
    }
}
