import MediaModel
import SwiftUI

/// Actions in the dock. Only available ones can be opened; the rest show
/// where the app is going and light up as they are built.
enum Tool: String, CaseIterable, Identifiable {
    case convert, crop, resize, compress, overlay, pdf, info

    var id: Self { self }

    var title: String {
        switch self {
        case .convert: "Convert"
        case .crop: "Crop"
        case .resize: "Resize"
        case .compress: "Compress"
        case .overlay: "Overlay"
        case .pdf: "PDF"
        case .info: "Info"
        }
    }

    var symbol: String {
        switch self {
        case .convert: "arrow.triangle.2.circlepath"
        case .crop: "crop"
        case .resize: "arrow.up.left.and.arrow.down.right"
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .overlay: "square.on.square"
        case .pdf: "doc.richtext"
        case .info: "info.circle"
        }
    }

    var isAvailable: Bool { [.convert, .crop, .resize, .info].contains(self) }
}

/// The open-file layout: preview and dock on the left, the chosen tool's
/// glass panel on the right, everything floating over the backdrop.
struct Workspace: View {
    let document: ImageDocument
    @Binding var tool: Tool?

    var body: some View {
        HStack(spacing: 18) {
            VStack(spacing: 16) {
                PreviewCanvas(document: document, isCropping: tool == .crop)
                    .overlay(alignment: .bottom) {
                        if tool != .convert { ExportToast(document: document) }
                    }
                ActionDock(selection: $tool)
            }

            if let tool {
                ToolPanel(tool: tool, document: document) { self.tool = nil }
                    .frame(width: Theme.panelWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.top, Theme.contentTop)
        .padding([.horizontal, .bottom], 18)
        .overlay(alignment: .top) { TopBar(document: document) }
        .ignoresSafeArea(.container, edges: .top)
        .animation(.spring(duration: 0.3), value: tool)
    }
}

// MARK: - Top bar

/// Sits in the (hidden) title bar next to the traffic lights.
private struct TopBar: View {
    let document: ImageDocument

    var body: some View {
        HStack(spacing: 12) {
            if let url = document.sourceURL {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let info = document.info {
                let output = document.plan?.outputDisplaySize
                let edited = output.map { $0 != info.displaySize } ?? false
                Text(verbatim: "\(info.displayWidth) × \(info.displayHeight)"
                     + (edited ? " → \(output!.width) × \(output!.height)" : "")
                     + "  ·  \(ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file))")
                    .font(.technicalSmall)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if document.preview?.isHDR == true {
                Label("HDR", systemImage: "sun.max.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .glassEffect()
                    .help("This photo has an HDR gain map. On HDR displays its highlights are brighter than white.")
            }
            Button("Open", systemImage: "folder") { document.presentOpenPanel() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .tint(.clear)
                .controlSize(.small)
                .help("Open an image (⌘O)")
        }
        .padding(.leading, Theme.titlebarInset)
        .padding(.trailing, 18)
        .frame(height: Theme.titlebarHeight)
        .background(Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()))
    }
}

// MARK: - Preview

private struct PreviewCanvas: View {
    let document: ImageDocument
    let isCropping: Bool

    var body: some View {
        ZStack {
            if document.preview != nil {
                ImageStage(document: document, isCropping: isCropping)
            } else if let error = document.loadError {
                ContentUnavailableView("Can't open this file", systemImage: "exclamationmark.triangle", description: Text(error))
                    .padding(30)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.panelCorner))
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }
}

// MARK: - Export toast

/// Export progress and results stay visible when the Convert panel is closed.
private struct ExportToast: View {
    let document: ImageDocument

    var body: some View {
        Group {
            switch document.exportState {
            case .running(let fraction):
                ProgressView(value: fraction).tint(Theme.ember).frame(width: 180)
            case .saved(let url):
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Saved \(url.lastPathComponent)").font(.callout).lineLimit(1)
                    Button("Show in Finder") { document.revealInFinder(url) }
                        .buttonStyle(.link)
                        .tint(Theme.ember)
                }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .padding(.bottom, 18)
        .opacity(document.exportState == .idle ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: document.exportState)
    }
}

// MARK: - Dock

private struct ActionDock: View {
    @Binding var selection: Tool?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Tool.allCases.enumerated()), id: \.element) { index, tool in
                if tool == .info {
                    Divider().frame(height: 30).padding(.horizontal, 6)
                }
                DockButton(tool: tool, isSelected: selection == tool) {
                    selection = selection == tool ? nil : tool
                }
            }
        }
        .padding(6)
        .background {
            // ⌘1…⌘7 always open a tool; clicking the open one closes it.
            ForEach(Array(Tool.allCases.enumerated()), id: \.element) { index, tool in
                Button(tool.title) { selection = tool }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .disabled(!tool.isAvailable)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct DockButton: View {
    let tool: Tool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .frame(height: 20)
                Text(tool.title)
                    .font(.caption2.weight(.medium))
            }
            .frame(width: 66, height: 50)
            .foregroundStyle(isSelected ? Theme.ember : .primary)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Theme.ember.opacity(0.16) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!tool.isAvailable)
        .opacity(tool.isAvailable ? 1 : 0.32)
        .help(tool.isAvailable ? tool.title : "\(tool.title): coming in a later build")
    }
}

// MARK: - Panel container

private struct ToolPanel: View {
    let tool: Tool
    let document: ImageDocument
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(tool.title, systemImage: tool.symbol)
                    .font(.headline)
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
            case .convert: ConvertPanel(document: document)
            case .crop: CropPanel(document: document)
            case .resize: ResizePanel(document: document)
            default: InfoPanel(document: document)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.panelCorner, style: .continuous))
    }
}
