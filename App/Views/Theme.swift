import AppKit
import SwiftUI

enum Theme {
    /// Molten ember: forge-hot orange-red, the one colour of the brand.
    static let ember = Color(red: 0.96, green: 0.36, blue: 0.15)
    static let panelWidth: CGFloat = 320
    static let panelCorner: CGFloat = 24
    /// Space the window's traffic-light buttons need at the leading edge.
    static let titlebarInset: CGFloat = 86
    /// Height of the row the traffic lights sit in (hidden title bar).
    static let titlebarHeight: CGFloat = 34
    /// Where content starts below that row.
    static let contentTop: CGFloat = 48
}

extension Font {
    /// Technical values (sizes, dimensions, formats) in SF Mono.
    static let technical = Font.system(.callout, design: .monospaced)
    static let technicalSmall = Font.system(.caption, design: .monospaced)
}

/// The window backdrop: near-black with the grain texture at low opacity
/// and a soft vignette, so glass panels have something to blur.
struct Backdrop: View {
    @MainActor private static let texture: NSImage? = Bundle.main
        .url(forResource: "Texture", withExtension: "heic")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        Color(red: 0.045, green: 0.045, blue: 0.05)
            .overlay {
                if let texture = Self.texture {
                    Image(nsImage: texture)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .opacity(0.28)
                }
            }
            .overlay {
                RadialGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    center: .center, startRadius: 180, endRadius: 1100
                )
            }
            .clipped()
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// Small uppercase label above a group of controls.
struct PanelSectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
