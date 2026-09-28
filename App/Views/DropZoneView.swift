import MediaModel
import SwiftUI

/// The empty state: one obvious thing to do.
struct DropZoneView: View {
    let isTargeted: Bool
    let formats: [ImageFormat]
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Text("DEX")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .tracking(6)
                .foregroundStyle(.secondary)

            Image(systemName: "photo.badge.arrow.down")
                .font(.system(size: 50, weight: .ultraLight))
                .foregroundStyle(isTargeted ? Theme.ember : .primary.opacity(0.85))
                .symbolEffect(.bounce, value: isTargeted)

            VStack(spacing: 8) {
                Text("Drop an image")
                    .font(.title2.weight(.semibold))
                Text(formats.map(\.displayName).joined(separator: " · "))
                    .font(.technicalSmall)
                    .foregroundStyle(.secondary)
            }

            Button("Choose File…", action: choose)
                .controlSize(.large)
                .buttonStyle(.glass)
                .keyboardShortcut("o")
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 44)
        .frame(width: 440)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(
                    isTargeted ? Theme.ember : .white.opacity(0.08),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [7, 5] : [])
                )
        }
        .scaleEffect(isTargeted ? 1.02 : 1)
        .animation(.spring(duration: 0.25), value: isTargeted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }
}
