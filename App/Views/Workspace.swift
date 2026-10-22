import MediaModel
import SwiftUI

/// Actions in the dock. Only available ones can be opened; the rest show
/// where the app is going and light up as they are built.
enum Tool: String, CaseIterable, Identifiable {
    case convert, crop, compose, pdf, info

    var id: Self { self }

    var title: String {
        switch self {
        case .convert: "Convert"
        case .crop: "Crop"
        case .compose: "Compose"
        case .pdf: "PDF"
        case .info: "Info"
        }
    }

    var symbol: String {
        switch self {
        case .convert: "arrow.triangle.2.circlepath"
        case .crop: "crop"
        case .compose: "square.on.square"
        case .pdf: "doc.richtext"
        case .info: "info.circle"
        }
    }

    /// PDFs only get the PDF and Info tools; images get everything.
    func isAvailable(isPDF: Bool) -> Bool {
        isPDF ? (self == .pdf || self == .info) : true
    }
}

/// The open-file layout: preview and dock on the left, the chosen tool's
/// glass panel on the right, everything floating over the backdrop.
struct Workspace: View {
    @Bindable var document: ImageDocument
    private var tool: Tool? { document.tool }

    var body: some View {
        HStack(spacing: 18) {
            VStack(spacing: 16) {
                PreviewCanvas(document: document, isCropping: tool == .crop)
                    .overlay(alignment: .bottom) {
                        // Tool panels show export status in their footer.
                        if tool == nil || tool == .info { ExportToast(document: document) }
                    }
                ActionDock(selection: $document.tool, isPDF: document.isPDFDocument)
            }

            if tool == .crop, let drag = document.cropDrag {
                LoupePanel(document: document, drag: drag)
                    .frame(width: Theme.panelWidth)
            } else if let tool {
                ToolPanel(tool: tool, document: document) { document.tool = nil }
                    .frame(width: Theme.panelWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.top, Theme.contentTop)
        .padding([.horizontal, .bottom], 18)
        .overlay(alignment: .top) { TopBar(document: document) }
        .ignoresSafeArea(.container, edges: .top)
        .animation(.spring(duration: 0.3), value: tool)
        .task(id: document.estimateKey) { await document.refreshEstimate() }
        // The loupe's full-resolution pixels (hundreds of MB for big
        // photos) are only needed while cropping.
        .onChange(of: document.tool) { _, tool in
            if tool != .crop { document.releaseLoupe() }
        }
    }
}

// MARK: - Top bar

/// Sits in the (hidden) title bar next to the traffic lights.
private struct TopBar: View {
    let document: ImageDocument

    var body: some View {
        HStack(spacing: 12) {
            HomeButton(document: document)
            if document.sourceURL != nil {
                RenameButton(document: document)
                FileNameLabel(document: document)
            }
            if let pdf = document.pdfInfo {
                Text(verbatim: "\(pdf.pageCount) page\(pdf.pageCount == 1 ? "" : "s")  ·  \(ByteCountFormatter.string(fromByteCount: pdf.fileSize, countStyle: .file))")
                    .font(.technicalSmall)
                    .foregroundStyle(.secondary)
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

/// Closes the open file and returns to the drop zone.
struct HomeButton: View {
    let document: ImageDocument

    var body: some View {
        Button("Home", systemImage: "house") { document.goHome() }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .tint(.clear)
            .controlSize(.small)
            .help("Home (⇧⌘H)")
    }
}

/// The open file's name, shortened with "…" when long; the full name is
/// in the tooltip. Shows the export name once it has been changed.
struct FileNameLabel: View {
    let document: ImageDocument

    var body: some View {
        if let url = document.sourceURL {
            let name = document.outputName.map { "\($0) (from \(url.lastPathComponent))" } ?? url.lastPathComponent
            Text(document.outputName ?? url.deletingPathExtension().lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 240, alignment: .leading)
                .help(name)
        }
    }
}

/// A pencil that sets the name exports are saved under.
struct RenameButton: View {
    let document: ImageDocument
    @State private var isEditing = false
    @State private var text = ""

    var body: some View {
        Button("Rename", systemImage: "pencil") {
            text = document.exportBaseName
            isEditing = true
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .tint(.clear)
        .controlSize(.small)
        .help("Name the exported file")
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Save as").font(.headline)
                TextField("File name", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(commit)
                Text("Used when you export. The original file keeps its name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    if document.outputName != nil {
                        Button("Use original name") {
                            document.renameOutput("")
                            isEditing = false
                        }
                        .buttonStyle(.link)
                        .tint(Theme.ember)
                    }
                    Spacer()
                    Button("Done", action: commit)
                        .keyboardShortcut(.defaultAction)
                        .tint(Theme.ember)
                }
            }
            .padding(14)
        }
    }

    private func commit() {
        document.renameOutput(text)
        isEditing = false
    }
}

// MARK: - Preview

private struct PreviewCanvas: View {
    let document: ImageDocument
    let isCropping: Bool

    var body: some View {
        ZStack {
            if document.isPDFDocument {
                PageGrid(document: document)
            } else if document.tool == .pdf {
                PDFPagesStage(document: document)
            } else if document.preview != nil {
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
                    DismissButton { document.dismissExportStatus() }
                }
            case .failed(let message):
                HStack {
                    Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
                    DismissButton { document.dismissExportStatus() }
                }
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .floatingGlass(in: Capsule(), depth: 0.5)
        .padding(.bottom, 18)
        .opacity(document.exportState == .idle ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: document.exportState)
    }
}

// MARK: - Dock

private struct ActionDock: View {
    @Binding var selection: Tool?
    let isPDF: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Tool.allCases.enumerated()), id: \.element) { index, tool in
                if tool == .info {
                    Divider().frame(height: 30).padding(.horizontal, 6)
                }
                DockButton(tool: tool, isSelected: selection == tool, isAvailable: tool.isAvailable(isPDF: isPDF)) {
                    selection = selection == tool ? nil : tool
                }
            }
        }
        .padding(6)
        .background {
            // ⌘1…⌘5 always open a tool; clicking the open one closes it.
            ForEach(Array(Tool.allCases.enumerated()), id: \.element) { index, tool in
                Button(tool.title) { selection = tool }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .disabled(!tool.isAvailable(isPDF: isPDF))
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .floatingGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), depth: 0.6)
    }
}

private struct DockButton: View {
    let tool: Tool
    let isSelected: Bool
    let isAvailable: Bool
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
            .dockTile(isSelected: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.32)
        .help(isAvailable ? tool.title : "\(tool.title): for images only")
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
            case .compose: ComposePanel(document: document)
            case .pdf: PDFPanel(document: document)
            default: InfoPanel(document: document)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .floatingGlass(in: RoundedRectangle(cornerRadius: Theme.panelCorner, style: .continuous))
    }
}
