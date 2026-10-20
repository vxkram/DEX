import AppKit
import SwiftUI

/// DEX ▸ About DEX: identity, version and the credits the bundled
/// open-source code requires.
struct AboutView: View {
    @State private var pointer = Pointer()

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        ZStack {
            Backdrop(pointer: pointer)
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 10) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 112, height: 112)
                        Text("DEX")
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .tracking(6)
                        Text(version)
                            .font(.technicalSmall)
                            .foregroundStyle(.secondary)
                        Text("Take any image and quickly turn it into what you need, losslessly whenever it's possible, and honestly when it isn't.")
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 380)
                    }
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 12) {
                        PanelSectionHeader("Built with")
                        Credit(
                            name: "libjpeg-turbo 3.2.0",
                            detail: "Lossless JPEG crop and compression.",
                            note: "This software is based in part on the work of the Independent JPEG Group.",
                            licenses: [("License", "libjpeg-turbo-LICENSE"), ("IJG README", "libjpeg-turbo-README-IJG")]
                        )
                        Credit(
                            name: "libwebp 1.6.0",
                            detail: "WebP encoding. Copyright Google Inc.",
                            note: nil,
                            licenses: [("License (BSD)", "libwebp-LICENSE"), ("Patent grant", "libwebp-PATENTS")]
                        )
                        Credit(
                            name: "LAME 4.0",
                            detail: "MP3 encoding (lame.sourceforge.io), under the GNU LGPL. It ships unmodified as its own library, Lame.framework, which you may replace.",
                            note: nil,
                            licenses: [("License (LGPL)", "LAME-COPYING")]
                        )
                        Credit(
                            name: "Background texture",
                            detail: "Photo by who's denilo on Unsplash, under the Unsplash License.",
                            note: nil,
                            licenses: []
                        )
                        Credit(
                            name: "Apple frameworks",
                            detail: "ImageIO, Core Graphics, Accelerate, PDFKit, AVFoundation and SwiftUI do the rest.",
                            note: nil,
                            licenses: []
                        )
                    }
                    .padding(18)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .padding(24)
            }
            .scrollIndicators(.never)
        }
        .frame(width: 480, height: 560)
        .preferredColorScheme(.dark)
        .tint(Theme.ember)
    }
}

private struct Credit: View {
    let name: String
    let detail: String
    let note: String?
    let licenses: [(title: String, file: String)]
    @State private var shown: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.callout.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
            if let note {
                Text(note).font(.caption.italic()).foregroundStyle(.secondary)
            }
            if !licenses.isEmpty {
                HStack(spacing: 12) {
                    ForEach(licenses, id: \.file) { license in
                        Button(license.title) { shown = shown == license.file ? nil : license.file }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
            if let shown, let text = Self.license(shown) {
                ScrollView {
                    Text(text)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.3)))
            }
        }
    }

    private static func license(_ name: String) -> String? {
        Bundle.main.url(forResource: name, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}

/// Replaces the standard About item so it opens the DEX About window.
struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About DEX") { openWindow(id: "about") }
    }
}
