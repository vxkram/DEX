import SwiftUI

enum Theme {
    /// Molten ember: forge-hot orange-red, the one colour of the brand.
    static let ember = Color(red: 0.96, green: 0.36, blue: 0.15)
    /// The near-black behind everything; also the window's own background,
    /// so a resize never flashes another colour at the edge.
    static let base = Color(red: 0.045, green: 0.045, blue: 0.05)
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
