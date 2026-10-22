import AppKit
import AudioEngine
import MediaModel
import SwiftUI

/// The open-audio layout: waveform and dock on the left, the chosen tool's
/// panel on the right, like the image workspace.
struct AudioWorkspace: View {
    let document: ImageDocument
    @Bindable var audio: AudioDocument

    var body: some View {
        HStack(spacing: 18) {
            VStack(spacing: 16) {
                AudioStage(audio: audio)
                AudioDock(selection: $audio.tool)
            }
            if let tool = audio.tool {
                AudioToolPanel(tool: tool, audio: audio) { audio.tool = nil }
                    .frame(width: Theme.panelWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.top, Theme.contentTop)
        .padding([.horizontal, .bottom], 18)
        .overlay(alignment: .top) { AudioTopBar(document: document, audio: audio) }
        .ignoresSafeArea(.container, edges: .top)
        .animation(.spring(duration: 0.3), value: audio.tool)
        .task(id: audio.request) { await audio.refreshEstimate() }
        .background { AudioShortcuts(audio: audio) }
        // Nothing starts with a text field focused.
        .onAppear { DispatchQueue.main.async { endTextEditing() } }
    }
}

// MARK: - Top bar

private struct AudioTopBar: View {
    let document: ImageDocument
    let audio: AudioDocument

    var body: some View {
        HStack(spacing: 12) {
            HomeButton(document: document)
            Text(audio.url.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if let info = audio.info {
                let edited = !audio.edit.isIdentity
                Text(verbatim: TimeText.string(info.frames, rate: info.sampleRate, precise: false)
                     + (edited ? " → " + TimeText.string(audio.outputLength, rate: info.sampleRate, precise: false) : "")
                     + "  ·  \(info.codecName) · \(AudioFacts.rate(info.sampleRate)) · \(AudioFacts.channels(info.channels))"
                     + "  ·  " + ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file))
                    .font(.technicalSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button("Open", systemImage: "folder") { document.presentOpenPanel() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .tint(.clear)
                .controlSize(.small)
                .help("Open a file (⌘O)")
        }
        .padding(.leading, Theme.titlebarInset)
        .padding(.trailing, 18)
        .frame(height: Theme.titlebarHeight)
        .background(Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()))
    }
}

// MARK: - Stage

/// Waveform, ruler, transport and overview in one glass panel.
private struct AudioStage: View {
    let audio: AudioDocument

    var body: some View {
        VStack(spacing: 0) {
            if let error = audio.loadError {
                ContentUnavailableView("Can't open this file", systemImage: "exclamationmark.triangle", description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if audio.info == nil {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Top half: what the file is (artwork, title, artist).
                ArtworkHeader(audio: audio)
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                // Bottom half: the timeline.
                TimeRuler(audio: audio)
                    .frame(height: 22)
                    .padding(.horizontal, 16 + TimelineEditor.inset)
                    .padding(.top, 10)
                TimelineEditor(audio: audio)
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, 16)
                OverviewStrip(audio: audio)
                    .frame(height: 30)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                TransportBar(audio: audio)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .floatingGlass(in: RoundedRectangle(cornerRadius: Theme.panelCorner, style: .continuous))
        .overlay(alignment: .bottom) {
            if audio.tool == nil || audio.tool == .info { AudioExportToast(audio: audio).padding(.bottom, 70) }
        }
    }
}

/// Maps between frames and x positions for the visible span.
struct TimelineScale {
    let visible: SampleRange
    let width: CGFloat

    func x(_ frame: Int64) -> CGFloat {
        guard visible.length > 0 else { return 0 }
        return CGFloat(Double(frame - visible.start) / Double(visible.length)) * width
    }

    func frame(_ x: CGFloat) -> Int64 {
        visible.start + Int64((Double(min(max(x, 0), width)) / Double(max(width, 1)) * Double(visible.length)).rounded())
    }
}

/// The waveform with the trim drawn on it, and the drag, pinch and scroll
/// gestures that edit it.
private struct TimelineEditor: View {
    let audio: AudioDocument
    @State private var mode: DragMode?
    @State private var lastMagnification: CGFloat = 1

    enum DragMode { case trimStart, trimEnd, scrub }

    var body: some View {
        GeometryReader { geometry in
            let scale = TimelineScale(visible: audio.visible, width: geometry.size.width)
            ZStack(alignment: .topLeading) {
                if let waveform = audio.waveform {
                    BarWaveform(waveform: waveform, visible: audio.visible, kept: audio.kept, playhead: audio.playhead,
                                style: .editor)
                        .padding(.vertical, 10)
                } else {
                    VStack(spacing: 8) {
                        ProgressView(value: audio.analysisProgress).tint(Theme.ember).frame(width: 180)
                        Text("Reading the audio…").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                TrimOverlay(audio: audio, scale: scale, height: geometry.size.height)
            }
            .contentShape(Rectangle())
            .gesture(drag(scale))
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        audio.zoom(by: value.magnification / lastMagnification,
                                   atFraction: value.startLocation.x / max(geometry.size.width, 1))
                        lastMagnification = value.magnification
                    }
                    .onEnded { _ in lastMagnification = 1 }
            )
            .background {
                ScrollWheelCatcher { deltaX, deltaY, zooms, precise, location in
                    let width = max(geometry.size.width, 1)
                    if zooms {
                        // Trackpads send many small deltas; a mouse wheel sends
                        // a few notches (sped up when spun), so each notch is
                        // one even step instead.
                        let factor = precise ? pow(1.01, Double(deltaY)) : pow(1.2, Double(min(max(deltaY, -3), 3)))
                        audio.zoom(by: factor, atFraction: location / width)
                    } else {
                        var delta = abs(deltaX) > abs(deltaY) ? -deltaX : -deltaY
                        if !precise { delta *= 12 }  // lines → points
                        audio.scrollVisible(to: audio.visible.start + Int64(Double(delta) / Double(width) * Double(audio.visible.length)))
                    }
                }
            }
        }
        // Room for the trim handles when they sit at the very start or end.
        .padding(.horizontal, Self.inset)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.28)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(minHeight: 110)
    }

    static let inset: CGFloat = 8

    private func drag(_ scale: TimelineScale) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let frame = scale.frame(value.location.x)
                if mode == nil {
                    endTextEditing()
                    mode = pick(at: value.startLocation.x, scale: scale)
                }
                switch mode {
                case .trimStart: audio.setTrimStart(frame)
                case .trimEnd: audio.setTrimEnd(frame)
                case .scrub, nil: audio.seek(to: frame)
                }
            }
            .onEnded { _ in mode = nil }
    }

    /// A trim handle within reach moves; anywhere else moves the playhead.
    private func pick(at x: CGFloat, scale: TimelineScale) -> DragMode {
        let reach: CGFloat = 10
        if abs(scale.x(audio.kept.start) - x) <= reach { return .trimStart }
        if abs(scale.x(audio.kept.end) - x) <= reach { return .trimEnd }
        return .scrub
    }
}

/// The audio as rounded bars sized by loudness. Bars inside the trim are
/// ember (brighter once played), the rest grey.
struct BarWaveform: View {
    enum Style {
        case editor, overview

        var barWidth: CGFloat { self == .editor ? 3 : 2 }
        var gap: CGFloat { self == .editor ? 1.5 : 1 }
    }

    let waveform: Waveform
    let visible: SampleRange
    let kept: SampleRange
    let playhead: Int64
    let style: Style

    var body: some View {
        Canvas { context, size in
            let step = style.barWidth + style.gap
            let count = max(Int(size.width / step), 1)
            let perBucket = Double(waveform.framesPerBucket)
            // Bars sit on a grid fixed in time, not on the screen, so
            // scrolling slides them instead of re-cutting (and flickering)
            // every bar.
            let barFrames = max(Double(visible.length) / Double(count), 1)
            let firstBar = (Double(visible.start) / barFrames).rounded(.down)
            let shift = (firstBar * barFrames - Double(visible.start)) / barFrames * step
            let bars = (0...count).map { index in
                let start = (firstBar + Double(index)) * barFrames
                let end = start + barFrames
                let first = Int(start / perBucket)
                let level = waveform.level(buckets: first..<max(Int(ceil(end / perBucket)), first + 1))
                return (level: level, middle: Int64((start + end) / 2))
            }
            // Scaled to the file's loudest moment, the same at every zoom,
            // so heights don't jump while zooming. Quiet files still fill.
            let reference = max(waveform.maxRMS, 1e-6)
            var played = Path(), unplayed = Path(), outside = Path()
            for (index, bar) in bars.enumerated() where CGFloat(index) * step + shift < size.width {
                // A gentle curve keeps quiet passages visible and loud ones
                // from all hitting the top.
                let height = max(CGFloat(pow(Double(min(bar.level / reference, 1)), 0.75)) * size.height * 0.96, 2)
                // Mirrored around the middle, like a waveform.
                let rect = CGRect(x: CGFloat(index) * step + shift, y: (size.height - height) / 2, width: style.barWidth, height: height)
                let path = Path(roundedRect: rect, cornerRadius: style.barWidth / 2)
                if !kept.contains(bar.middle) { outside.addPath(path) }
                else if bar.middle < playhead { played.addPath(path) }
                else { unplayed.addPath(path) }
            }
            context.fill(outside, with: .color(.white.opacity(style == .editor ? 0.22 : 0.18)))
            context.fill(unplayed, with: .color(Theme.ember.opacity(0.62)))
            context.fill(played, with: .color(Theme.ember))
        }
    }
}

/// The trim handles and the playhead.
private struct TrimOverlay: View {
    let audio: AudioDocument
    let scale: TimelineScale
    let height: CGFloat

    var body: some View {
        let kept = audio.kept
        ZStack(alignment: .topLeading) {
            TrimHandle(isStart: true, isActive: audio.tool == .trim).offset(x: scale.x(kept.start) - 5)
            TrimHandle(isStart: false, isActive: audio.tool == .trim).offset(x: scale.x(kept.end) - 5)
            let x = scale.x(audio.playhead)
            if x >= -1 && x <= scale.width + 1 {
                Rectangle().fill(.white).frame(width: 1.5, height: height).offset(x: x - 0.75)
            }
        }
        .frame(width: scale.width, height: height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

private struct TrimHandle: View {
    let isStart: Bool
    let isActive: Bool

    var body: some View {
        GeometryReader { geometry in
            UnevenRoundedRectangle(
                topLeadingRadius: isStart ? 4 : 0, bottomLeadingRadius: isStart ? 4 : 0,
                bottomTrailingRadius: isStart ? 0 : 4, topTrailingRadius: isStart ? 0 : 4
            )
            .fill(isActive ? Theme.ember : Theme.ember.opacity(0.6))
            .frame(width: 10, height: geometry.size.height)
            .overlay {
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in Capsule().fill(.white.opacity(0.85)).frame(width: 2, height: 8) }
                }
            }
        }
        .frame(width: 10)
    }
}

// MARK: - Ruler

private struct TimeRuler: View {
    let audio: AudioDocument

    var body: some View {
        GeometryReader { geometry in
            let scale = TimelineScale(visible: audio.visible, width: geometry.size.width)
            let rate = audio.sampleRate
            let seconds = Double(audio.visible.length) / rate
            let step = Self.steps.first { geometry.size.width / CGFloat(seconds / $0) >= 90 } ?? 3_600
            let first = (Double(audio.visible.start) / rate / step).rounded(.up) * step
            let ticks = Array(stride(from: first, through: Double(audio.visible.end) / rate, by: step).prefix(200))
            ZStack(alignment: .topLeading) {
                ForEach(ticks, id: \.self) { time in
                    let x = scale.x(Int64(time * rate))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: Self.label(time, step: step))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Rectangle().fill(.secondary.opacity(0.6)).frame(width: 1, height: 5)
                    }
                    .offset(x: x)
                }
            }
        }
        .clipped()
    }

    static let steps: [Double] = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1_800, 3_600]

    static func label(_ time: Double, step: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = time - Double(minutes * 60)
        let decimals = step < 0.01 ? 3 : step < 0.1 ? 2 : step < 1 ? 1 : 0
        return String(format: "%d:%0\(decimals > 0 ? decimals + 3 : 2).\(decimals)f", minutes, seconds)
    }
}

// MARK: - Overview

/// The whole file small, with a box around the trimmed part saying how
/// long it is. When zoomed, a white frame shows the visible span; drag to
/// move it.
private struct OverviewStrip: View {
    let audio: AudioDocument

    var body: some View {
        GeometryReader { geometry in
            let whole = SampleRange(0, max(audio.frames, 1))
            let scale = TimelineScale(visible: whole, width: geometry.size.width)
            let kept = audio.kept
            let keptWidth = max(scale.x(kept.end) - scale.x(kept.start), 6)
            let (width, height) = (geometry.size.width, geometry.size.height)
            let centre = scale.x(kept.start) + keptWidth / 2
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.25))
                if let waveform = audio.waveform {
                    BarWaveform(waveform: waveform, visible: whole, kept: kept, playhead: audio.playhead, style: .overview)
                        .padding(.vertical, 4)
                }
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.ember.opacity(0.14))
                    .strokeBorder(Theme.ember, lineWidth: 1.5)
                    .frame(width: keptWidth, height: geometry.size.height)
                    .offset(x: scale.x(kept.start))
                if audio.isZoomed {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(.white.opacity(0.85), lineWidth: 1)
                        .frame(width: max(scale.x(audio.visible.end) - scale.x(audio.visible.start), 4), height: geometry.size.height - 6)
                        .offset(x: scale.x(audio.visible.start), y: 3)
                }
                Rectangle().fill(.white).frame(width: 1, height: geometry.size.height).offset(x: scale.x(audio.playhead))
            }
            // What the box covers, on the box (or beside it when it's narrow).
            .overlay(alignment: .topLeading) {
                Text(verbatim: TimeText.string(kept.length, rate: audio.sampleRate))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.ember, in: Capsule())
                    .fixedSize()
                    .alignmentGuide(.leading) { label in -min(max(centre - label.width / 2, 2), width - label.width - 2) }
                    .alignmentGuide(.top) { label in -(height - label.height) / 2 }
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                endTextEditing()
                let frame = scale.frame(value.location.x)
                if audio.isZoomed {
                    audio.scrollVisible(to: frame - audio.visible.length / 2)
                } else {
                    audio.seek(to: frame)
                }
            })
        }
        .help(audio.isZoomed ? "Drag to move through the file" : "The whole file; the box is what you keep")
    }
}

// MARK: - Transport

private struct TransportBar: View {
    let audio: AudioDocument

    var body: some View {
        HStack(spacing: 14) {
            Button(audio.isPlaying ? "Pause" : "Play", systemImage: audio.isPlaying ? "pause.fill" : "play.fill") {
                endTextEditing()
                audio.togglePlayback()
            }
            .focusable(false)
            .labelStyle(.iconOnly)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 36, height: 36)
            .buttonStyle(.glass)
            .help("Play the trimmed audio (Space)")

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: TimeText.string(audio.playhead, rate: audio.sampleRate))
                    .font(.system(.title3, design: .monospaced, weight: .medium))
                Text(verbatim: "Result " + TimeText.string(audio.outputLength, rate: audio.sampleRate))
                    .font(.technicalSmall)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                ZoomButton("Zoom out", "minus.magnifyingglass") { audio.zoom(by: 0.5) }
                    .keyboardShortcut("-", modifiers: .command)
                ZoomButton("Zoom in", "plus.magnifyingglass") { audio.zoom(by: 2) }
                    .keyboardShortcut("=", modifiers: .command)
                ZoomButton("Zoom to the trim", "arrow.up.left.and.down.right.magnifyingglass") { audio.zoomToTrim() }
                ZoomButton("Show the whole file", "arrow.left.and.right") { audio.zoomToFit() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(!audio.isZoomed)
            }
        }
    }
}

private struct ZoomButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    init(_ title: String, _ symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .frame(width: 26, height: 26)
            .help(title)
    }
}

// MARK: - Keyboard

/// Space plays, I/O set the trim, ←/→ move a second. A key monitor rather than shortcut buttons, so the
/// keys still type normally in the time fields.
private struct AudioShortcuts: NSViewRepresentable {
    let audio: AudioDocument

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.handle = handle
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.handle = handle
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 49: audio.togglePlayback()
        case 123: audio.seek(to: audio.playhead - Int64(audio.sampleRate))
        case 124: audio.seek(to: audio.playhead + Int64(audio.sampleRate))
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "i": audio.setTrimStart(audio.playhead)
            case "o": audio.setTrimEnd(audio.playhead)
            default: return false
            }
        }
        return true
    }

    final class MonitorView: NSView {
        var handle: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window,
                      !(self.window?.firstResponder is NSText),
                      self.window?.attachedSheet == nil
                else { return event }
                return self.handle?(event) == true ? nil : event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}

/// Catches scroll-wheel and trackpad scrolling over the waveform without
/// taking clicks from the SwiftUI gestures above it.
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (_ deltaX: CGFloat, _ deltaY: CGFloat, _ zooms: Bool, _ precise: Bool, _ x: CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, CGFloat, Bool, Bool, CGFloat) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                let zooms = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option)
                self.onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, zooms, event.hasPreciseScrollingDeltas, point.x)
                return nil
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}

// MARK: - Dock and panel

private struct AudioDock: View {
    @Binding var selection: AudioTool?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AudioTool.allCases) { tool in
                if tool == .info {
                    Divider().frame(height: 30).padding(.horizontal, 6)
                }
                Button {
                    selection = selection == tool ? nil : tool
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tool.symbol).font(.system(size: 16, weight: .medium)).frame(height: 20)
                        Text(tool.title).font(.caption2.weight(.medium))
                    }
                    .frame(width: 66, height: 50)
                    .foregroundStyle(selection == tool ? Theme.ember : .primary)
                    .dockTile(isSelected: selection == tool)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(tool.title)
            }
        }
        .padding(6)
        .background {
            ForEach(Array(AudioTool.allCases.enumerated()), id: \.element) { index, tool in
                Button(tool.title) { selection = tool }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .floatingGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), depth: 0.6)
    }
}

private struct AudioToolPanel: View {
    let tool: AudioTool
    let audio: AudioDocument
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(tool.title, systemImage: tool.symbol).font(.headline)
                Spacer()
                Button("Close", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            switch tool {
            case .trim: TrimPanel(audio: audio)
            case .convert: AudioConvertPanel(audio: audio)
            case .info: AudioInfoPanel(audio: audio)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .floatingGlass(in: RoundedRectangle(cornerRadius: Theme.panelCorner, style: .continuous))
    }
}

/// Export progress and results while no tool panel is open.
private struct AudioExportToast: View {
    let audio: AudioDocument

    var body: some View {
        Group {
            switch audio.exportState {
            case .running(let fraction):
                ProgressView(value: fraction).tint(Theme.ember).frame(width: 180)
            case .saved(let url):
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Saved \(url.lastPathComponent)").font(.callout).lineLimit(1)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.link)
                        .tint(Theme.ember)
                    DismissButton { audio.dismissExportStatus() }
                }
            case .failed(let message):
                HStack {
                    Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
                    DismissButton { audio.dismissExportStatus() }
                }
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .floatingGlass(in: Capsule(), depth: 0.5)
        .opacity(audio.exportState == .idle ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: audio.exportState)
    }
}

/// Takes keyboard focus out of the tag fields, so Space, I and O reach
/// the timeline again.
@MainActor
func endTextEditing() {
    if NSApp.keyWindow?.firstResponder is NSText { NSApp.keyWindow?.makeFirstResponder(nil) }
}

enum AudioFacts {
    static func rate(_ rate: Double) -> String {
        let khz = rate / 1000
        return (khz == khz.rounded() ? "\(Int(khz))" : String(format: "%.1f", khz)) + " kHz"
    }

    static func channels(_ count: Int) -> String {
        switch count {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(count) ch"
        }
    }
}
