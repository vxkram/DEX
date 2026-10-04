import AppKit
import SwiftUI

// Depth: the backdrop sits furthest back, glass panels float above it with
// real shadows, and a little motion (parallax, hover lift and drift) sells the
// layering. All motion stops under Reduce Motion.

// MARK: - Pointer

/// Where the pointer is over the window, as a unit point. Only the backdrop
/// layers read it, so moving the mouse doesn't redraw the workspace.
@MainActor @Observable
final class Pointer {
    /// Where the light rests when the pointer is away: up and centre, like
    /// a lamp above the desk.
    static let rest = CGPoint(x: 0.5, y: 0.28)

    private(set) var location = rest
    @ObservationIgnored var size = CGSize(width: 1, height: 1)

    func update(_ phase: HoverPhase) {
        switch phase {
        case .active(let point):
            location = CGPoint(x: point.x / max(size.width, 1), y: point.y / max(size.height, 1))
        case .ended:
            location = Self.rest
        }
    }
}

// MARK: - Backdrop

/// The window backdrop: near-black with the grain texture, an ember light
/// that follows the pointer, and darker edges.
///
/// The texture is a fixed-size sheet anchored to the screen while the
/// window resizes, so resizing reveals more of it instead of zooming and
/// sliding it (it used to scale-to-fill around the centre on every frame).
struct Backdrop: View {
    let pointer: Pointer

    var body: some View {
        Theme.base
            .overlay { Wallpaper(pointer: pointer) }
            .overlay { PointerGlow(pointer: pointer) }
            .overlay { EdgeShade() }
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct Wallpaper: NSViewRepresentable {
    let pointer: Pointer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @MainActor static let texture: CGImage? = Bundle.main
        .url(forResource: "Texture", withExtension: "heic")
        .flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
        .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }

    func makeNSView(context: Context) -> WallpaperView {
        WallpaperView(image: Self.texture)
    }

    func updateNSView(_ view: WallpaperView, context: Context) {
        // The texture drifts a few points against the pointer: it is the
        // furthest layer, so it moves least and the opposite way.
        let p = reduceMotion ? CGPoint(x: 0.5, y: 0.5) : pointer.location
        view.setParallax(CGSize(width: (0.5 - p.x) * 18, height: (p.y - 0.5) * 12))
    }
}

/// Draws the texture in a layer whose position only changes when the
/// window's top-left corner moves during a resize; moving the window
/// carries the texture along, like a print on the glass.
final class WallpaperView: NSView {
    /// Room for the parallax drift on every side.
    private static let margin: CGFloat = 16

    private let drift = CALayer()
    private let texture = CALayer()
    /// Texture top-left relative to the view's top-left (x right, y up).
    private var anchor: CGPoint?
    private var lastWindowFrame: NSRect?

    init(image: CGImage?) {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        texture.contents = image
        texture.contentsGravity = .resizeAspectFill
        texture.opacity = 0.28
        texture.masksToBounds = true
        drift.addSublayer(texture)
        layer?.addSublayer(drift)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        anchor = nil
        lastWindowFrame = nil
        reposition()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reposition()
    }

    override func layout() {
        super.layout()
        reposition()
    }

    func setParallax(_ offset: CGSize) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.9)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        drift.setAffineTransform(CGAffineTransform(translationX: offset.width, y: offset.height))
        CATransaction.commit()
    }

    /// Big enough to cover the largest screen, so no window size needs it
    /// scaled.
    private var sheetSize: CGSize {
        let screens = NSScreen.screens.map(\.frame.size)
        let width = screens.map(\.width).max() ?? 2560
        let height = screens.map(\.height).max() ?? 1600
        return CGSize(width: max(width, bounds.width) + Self.margin * 2,
                      height: max(height, bounds.height) + Self.margin * 2)
    }

    private func reposition() {
        guard let window, bounds.width > 0, bounds.height > 0 else { return }
        let sheet = sheetSize
        let frame = window.frame
        var anchor = anchor ?? CGPoint(x: -(sheet.width - bounds.width) / 2,
                                       y: (sheet.height - bounds.height) / 2)
        if let last = lastWindowFrame, last.size != frame.size {
            // Resizing: hold the texture still on screen.
            anchor.x -= frame.minX - last.minX
            anchor.y -= frame.maxY - last.maxY
        }
        lastWindowFrame = frame
        // Always cover the view, with room left for the drift.
        let m = Self.margin
        anchor.x = min(-m, max(anchor.x, bounds.width - sheet.width + m))
        anchor.y = max(m, min(anchor.y, sheet.height - bounds.height - m))
        self.anchor = anchor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drift.frame = bounds
        texture.contentsScale = window.backingScaleFactor
        texture.frame = CGRect(x: anchor.x, y: bounds.height + anchor.y - sheet.height,
                               width: sheet.width, height: sheet.height)
        CATransaction.commit()
    }
}

/// A soft ember light under the glass that follows the pointer slowly.
private struct PointerGlow: View {
    let pointer: Pointer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let diameter = max(size.width, size.height) * 1.1
            let p = reduceMotion ? Pointer.rest : pointer.location
            Circle()
                .fill(RadialGradient(
                    colors: [Theme.ember.opacity(0.16), Theme.ember.opacity(0.05), .clear],
                    center: .center, startRadius: 0, endRadius: diameter / 2
                ))
                .frame(width: diameter, height: diameter)
                .position(x: p.x * size.width, y: p.y * size.height)
                .animation(.smooth(duration: 1.4), value: p)
                .blendMode(.plusLighter)
        }
    }
}

/// Darker edges, heavier at the bottom, as if lit from above. Fixed widths
/// in points, so they stay put while the window resizes.
private struct EdgeShade: View {
    var body: some View {
        GeometryReader { geometry in
            let x = min(0.35, 260 / max(geometry.size.width, 1))
            let top = min(0.3, 160 / max(geometry.size.height, 1))
            let bottom = min(0.4, 260 / max(geometry.size.height, 1))
            ZStack {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.5), location: 0),
                    .init(color: .clear, location: x),
                    .init(color: .clear, location: 1 - x),
                    .init(color: .black.opacity(0.5), location: 1),
                ], startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.35), location: 0),
                    .init(color: .clear, location: top),
                    .init(color: .clear, location: 1 - bottom),
                    .init(color: .black.opacity(0.6), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

// MARK: - Floating glass

extension View {
    /// Liquid Glass lifted off the backdrop: a shadow cast below it and a
    /// thin highlight along its top edge. `depth` 1 is a panel; smaller
    /// values sit closer to the backdrop (docks, toasts).
    func floatingGlass<S: InsettableShape>(in shape: S, depth: CGFloat = 1) -> some View {
        glassEffect(.regular, in: shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.03), .clear],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            }
            .background { CastShadow(shape: shape, depth: depth) }
    }

    /// Floats toward the pointer while it's over the view.
    func hoverFloat(_ maxDrift: CGFloat = 5) -> some View {
        modifier(HoverFloat(maxDrift: maxDrift))
    }

    /// A dock button that lifts under the pointer; the selected one glows.
    func dockTile(isSelected: Bool) -> some View {
        modifier(DockTile(isSelected: isSelected))
    }
}

/// Only the shadow: the shape's own area is cut out, so the glass above
/// still sees the backdrop, not a dark fill.
private struct CastShadow<S: Shape>: View {
    let shape: S
    let depth: CGFloat

    var body: some View {
        shape.fill(.black)
            .shadow(color: .black.opacity(0.42), radius: 30 * depth, y: 18 * depth)
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1.5)
            .mask {
                ZStack {
                    Rectangle().padding(-120)
                    shape.blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The card drifts toward the pointer and lifts a little; the backdrop
/// drifts the other way, so the two read as layers. (A real 3D tilt would
/// flatten Liquid Glass into an opaque card, so it's a 2D drift.)
private struct HoverFloat: ViewModifier {
    let maxDrift: CGFloat
    @State private var drift = CGSize.zero
    @State private var isHovered = false
    @State private var size = CGSize(width: 1, height: 1)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered ? 1.01 : 1)
            .offset(drift)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onContinuousHover { phase in
                guard !reduceMotion else { return }
                withAnimation(.smooth(duration: 0.8)) {
                    switch phase {
                    case .active(let point):
                        isHovered = true
                        drift = CGSize(width: (point.x / max(size.width, 1) - 0.5) * 2 * maxDrift,
                                       height: (point.y / max(size.height, 1) - 0.5) * 2 * maxDrift)
                    case .ended:
                        isHovered = false
                        drift = .zero
                    }
                }
            }
    }
}

private struct DockTile: ViewModifier {
    let isSelected: Bool
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let lifted = isHovered && isEnabled && !reduceMotion
        content
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Theme.ember.opacity(0.18) : .white.opacity(isHovered && isEnabled ? 0.07 : 0))
                    .shadow(color: isSelected ? Theme.ember.opacity(0.45) : .clear, radius: 10, y: 2)
            }
            .scaleEffect(lifted ? 1.06 : 1)
            .offset(y: lifted ? -2 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: lifted)
            .animation(.easeOut(duration: 0.2), value: isSelected)
            .onHover { isHovered = $0 }
    }
}
