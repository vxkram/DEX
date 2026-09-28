import MediaModel
import SwiftUI

/// The empty state: one obvious thing to do.
struct DropZoneView: View {
    let isTargeted: Bool
    let formats: [ImageFormat]
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.badge.arrow.down")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(isTargeted ? Color.dexAccent : .secondary)
                .symbolEffect(.bounce, value: isTargeted)

            VStack(spacing: 6) {
                Text("Drop an image")
                    .font(.title2.weight(.semibold))
                Text(formats.map(\.displayName).joined(separator: " · "))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }

            Button("Choose File…", action: choose)
                .controlSize(.large)
                .buttonStyle(.glass)
                .keyboardShortcut("o")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.dexAccent : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: isTargeted ? 2.5 : 1.5, dash: [8, 6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(isTargeted ? Color.dexAccent.opacity(0.07) : .clear)
                )
                .padding(28)
        }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}
