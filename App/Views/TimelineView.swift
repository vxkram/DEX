import ImageEngine
import MediaModel
import SwiftUI

/// The frames of an animated GIF or WebP under the preview: a filmstrip with
/// a playhead and, when saving a GIF, trim handles.
struct TimelineView: View {
    let document: ImageDocument
    let animation: AnimationFrames

    @State private var dragging: Part?

    private enum Part { case playhead, start, end }

    var body: some View {
        let count = animation.frames.count
        let trimming = document.keepsAnimation
        let range = document.trimRange
        HStack(spacing: 12) {
            Button(document.isPlaying ? "Pause" : "Play", systemImage: document.isPlaying ? "pause.fill" : "play.fill") {
                document.togglePlayback()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .controlSize(.large)
            .help("Play or pause (Space)")

            GeometryReader { proxy in
                let width = proxy.size.width
                let x = { (frame: Int) in count > 1 ? CGFloat(frame) / CGFloat(count - 1) * width : 0 }
                ZStack(alignment: .topLeading) {
                    Filmstrip(frames: animation.frames)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    if trimming {
                        Color.black.opacity(0.6).frame(width: x(range.lowerBound))
                        Color.black.opacity(0.6).frame(width: max(width - x(range.upperBound), 0))
                            .offset(x: x(range.upperBound))
                        TrimHandle().offset(x: x(range.lowerBound) - 5)
                        TrimHandle().offset(x: x(range.upperBound) - 5)
                    }
                    Capsule().fill(.white)
                        .frame(width: 3)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .offset(x: x(document.playhead) - 1.5)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let frame = Int((min(max(value.location.x / max(width, 1), 0), 1) * CGFloat(count - 1)).rounded())
                        if dragging == nil {
                            // Grab a trim handle when the drag starts on one.
                            let start = value.startLocation.x
                            dragging = trimming && abs(start - x(range.lowerBound)) < 10 ? .start
                                : trimming && abs(start - x(range.upperBound)) < 10 ? .end : .playhead
                        }
                        switch dragging {
                        case .start: document.setTrim(start: frame)
                        case .end: document.setTrim(end: frame)
                        default: document.seek(to: frame)
                        }
                    }
                    .onEnded { _ in dragging = nil })
            }
            .frame(height: 44)

            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: "\(document.playhead + 1) / \(count)")
                    .font(.technical)
                Text(verbatim: caption(range: range, trimming: trimming))
                    .font(.technicalSmall)
                    .foregroundStyle(trimming ? .secondary : Theme.ember)
            }
            .frame(minWidth: 96, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .floatingGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), depth: 0.5)
        .background {
            KeyMonitor { event in
                guard event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
                document.togglePlayback()
                return true
            }
        }
    }

    /// "2.4 s · 36 frames" for a GIF, or which frame a still export keeps.
    private func caption(range: ClosedRange<Int>, trimming: Bool) -> String {
        guard trimming else { return "saves frame \(document.playhead + 1)" }
        let seconds = String(format: "%.1f s", animation.duration(of: range))
        return "\(seconds) · \(range.count) frames"
    }
}

/// Evenly spaced frames, as many as fit at their own shape.
private struct Filmstrip: View {
    let frames: [CGImage]

    var body: some View {
        Canvas { context, size in
            guard let first = frames.first else { return }
            let aspect = CGFloat(first.width) / CGFloat(max(first.height, 1))
            let tile = max(size.height * aspect, 8)
            let shown = max(1, min(frames.count, Int((size.width / tile).rounded(.up))))
            for i in 0..<shown {
                let index = shown > 1 ? Int((Double(i) / Double(shown - 1) * Double(frames.count - 1)).rounded()) : 0
                let rect = CGRect(x: CGFloat(i) * tile, y: 0, width: tile, height: size.height)
                context.draw(Image(decorative: frames[index], scale: 1), in: rect)
            }
        }
        .background(Color.black.opacity(0.3))
    }
}

private struct TrimHandle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Theme.ember)
            .frame(width: 10, height: 44)
            .overlay(Capsule().fill(.white.opacity(0.85)).frame(width: 2, height: 16))
            .shadow(color: .black.opacity(0.4), radius: 2)
            .allowsHitTesting(false)
    }
}
