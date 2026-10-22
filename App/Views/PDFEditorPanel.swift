import ImageEngine
import MediaModel
import PDFKit
import SwiftUI

/// An open PDF: edit it (pages, add, text, split, compress) or turn pages
/// into images.
struct PDFDocumentPanel: View {
    @Bindable var document: ImageDocument

    var body: some View {
        Picker("Mode", selection: $document.pdfMode) {
            Text("Edit").tag(PDFMode.edit)
            Text("To images").tag(PDFMode.images)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)

        switch document.pdfMode {
        case .images: PDFToImages(document: document)
        case .edit: PDFEditSections(document: document)
        }
    }
}

private struct PDFEditSections: View {
    @Bindable var document: ImageDocument

    var body: some View {
        let selected = document.selectedIndices
        let total = document.pdfPages.count

        VStack(alignment: .leading, spacing: 8) {
            PanelSectionHeader("Pages")
            HStack {
                Text(verbatim: "\(selected.count) of \(total) selected").font(.technical)
                Spacer()
                Button("All") { document.selectAllPages() }.buttonStyle(.link).tint(Theme.ember)
                Button("None") { document.selectNoPages() }.buttonStyle(.link).tint(Theme.ember)
            }
            HStack(spacing: 6) {
                IconButton("Rotate left", "rotate.left") { document.rotateSelectedPages(clockwise: false) }
                IconButton("Rotate right", "rotate.right") { document.rotateSelectedPages(clockwise: true) }
                IconButton("Move earlier", "arrow.left") { document.moveSelectedPages(by: -1) }
                IconButton("Move later", "arrow.right") { document.moveSelectedPages(by: 1) }
                IconButton("Delete", "trash") { document.deleteSelectedPages() }
            }
            .disabled(selected.isEmpty)
            Button("Extract selected pages to a new PDF…") { document.presentSaveEditedPDFPanel(selectedOnly: true) }
                .buttonStyle(.link).tint(Theme.ember).font(.caption.weight(.semibold))
                .disabled(selected.isEmpty)
            Explanation("Click to select, drag to move.")
        }

        VStack(alignment: .leading, spacing: 8) {
            PanelSectionHeader("Add")
            HStack(spacing: 8) {
                Button { document.presentAddPDFPanel() } label: {
                    Label("PDF…", systemImage: "doc.badge.plus").frame(maxWidth: .infinity, minHeight: 30)
                }
                Button { document.presentAddImagePagesPanel() } label: {
                    Label("Images…", systemImage: "photo.badge.plus").frame(maxWidth: .infinity, minHeight: 30)
                }
            }
            .buttonStyle(.glass)
            Explanation(selected.isEmpty ? "Added at the end." : "Added after page \(selected.last! + 1).")
        }

        VStack(alignment: .leading, spacing: 8) {
            PanelSectionHeader("Text")
            TextField("Text to add", text: $document.pdfText)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                ForEach(PDFTextColor.allCases) { color in
                    Circle()
                        .fill(Color(nsColor: color.color))
                        .overlay(Circle().strokeBorder(document.pdfTextColor == color ? Theme.ember : .white.opacity(0.3), lineWidth: 2))
                        .frame(width: 22, height: 22)
                        .onTapGesture { document.pdfTextColor = color }
                        .accessibilityLabel(color.rawValue)
                }
                Spacer()
                PositionGrid(selection: $document.pdfTextPosition)
            }
            LabeledSlider(title: "Size", value: document.pdfTextSize, range: 8...72, display: "\(Int(document.pdfTextSize)) pt") {
                document.pdfTextSize = $0.rounded()
            }
            Button("Add to page \((selected.first ?? 0) + 1)") { document.addTextToSelectedPage() }
                .buttonStyle(.glass)
                .disabled(selected.isEmpty || document.pdfText.isEmpty)
        }

        VStack(alignment: .leading, spacing: 8) {
            PanelSectionHeader("Split")
            Picker("Split", selection: $document.splitMode) {
                Text("Every page").tag(SplitMode.everyPage)
                Text("Every N").tag(SplitMode.everyN)
                Text("At selection").tag(SplitMode.atSelection)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if document.splitMode == .everyN {
                Stepper(value: $document.splitEvery, in: 2...max(total, 2)) {
                    Text(verbatim: "Every \(document.splitEvery) pages").font(.callout)
                }
            }
            if document.splitMode == .atSelection {
                Explanation("A new PDF starts at each selected page.")
            }
            Button("Split into PDFs…") { document.splitToFolder() }
                .buttonStyle(.glass)
        }

        VStack(alignment: .leading, spacing: 8) {
            PanelSectionHeader("Save")
            HStack(spacing: 6) {
                TwoLineChip(title: "Original", subtitle: "as is", isSelected: document.pdfCompression == .none) { document.pdfCompression = .none }
                TwoLineChip(title: "Balanced", subtitle: "images JPEG", isSelected: document.pdfCompression == .balanced) { document.pdfCompression = .balanced }
                TwoLineChip(title: "Smallest", subtitle: "email / web", isSelected: document.pdfCompression == .smallest) { document.pdfCompression = .smallest }
            }
            EditedPDFSize(document: document)
            if document.pdfEdited {
                Button("Revert all edits", systemImage: "arrow.counterclockwise") { document.revertPDF() }
                    .buttonStyle(.link).tint(Theme.ember).font(.caption)
            }
        }
    }
}

private struct EditedPDFSize: View {
    let document: ImageDocument

    var body: some View {
        HStack(spacing: 6) {
            if let estimate = document.editedPDFEstimate, estimate.key == document.editedEstimateKey, let bytes = estimate.bytes {
                Image(systemName: "doc").foregroundStyle(.secondary)
                Text(verbatim: "≈ " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.technical)
                if let original = document.pdfInfo?.fileSize, original > 0 {
                    let change = Double(bytes - original) / Double(original)
                    Text(verbatim: change.magnitude < 0.01 ? "same size" : "\(Int((change.magnitude * 100).rounded()))% \(change < 0 ? "smaller" : "larger")")
                        .font(.technicalSmall)
                        .foregroundStyle(change < -0.01 ? .green : change > 0.01 ? .orange : .secondary)
                }
            } else {
                ProgressView().controlSize(.mini)
                Text("Measuring…").font(.technicalSmall).foregroundStyle(.secondary)
            }
        }
        .task(id: document.editedEstimateKey) { await document.refreshEditedPDFEstimate() }
    }
}

/// Nine-point picker for where text goes.
private struct PositionGrid: View {
    @Binding var selection: PDFEditor.TextPosition

    var body: some View {
        let positions = PDFEditor.TextPosition.allCases
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<3) { row in
                GridRow {
                    ForEach(0..<3) { column in
                        let position = positions[row * 3 + column]
                        RoundedRectangle(cornerRadius: 3)
                            .fill(selection == position ? Theme.ember : .white.opacity(0.12))
                            .frame(width: 18, height: 13)
                            .onTapGesture { selection = position }
                    }
                }
            }
        }
        .help("Where the text goes on the page")
    }
}

// MARK: - Page grid (preview area for PDFs)

struct PageGrid: View {
    @Bindable var document: ImageDocument

    var body: some View {
        if document.pdfEditor != nil {
            let pages = document.pdfPages
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 18)], spacing: 18) {
                    ForEach(Array(pages.enumerated()), id: \.element) { index, page in
                        PageTile(page: page, number: index + 1, rotation: page.rotation,
                                 isSelected: document.selectedPageIDs.contains(ObjectIdentifier(page))) {
                            document.togglePage(page)
                        }
                        .draggable(String(index))
                        .dropDestination(for: String.self) { items, _ in
                            guard let from = items.first.flatMap(Int.init) else { return false }
                            document.dropPage(from, before: index)
                            return true
                        }
                    }
                }
                .padding(24)
            }
        } else if document.needsPDFPassword {
            ContentUnavailableView("Password required", systemImage: "lock.fill", description: Text("This PDF is protected."))
        } else {
            ProgressView().controlSize(.large)
        }
    }
}

private struct PageTile: View {
    let page: PDFPage
    let number: Int
    let rotation: Int
    let isSelected: Bool
    let toggle: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle().fill(.white.opacity(0.9)).aspectRatio(0.707, contentMode: .fit)
                            .overlay(ProgressView().controlSize(.small))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                .opacity(isSelected ? 1 : 0.5)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.ember : .white.opacity(0.8))
                    .background(Circle().fill(.black.opacity(0.35)))
                    .padding(6)
            }
            Text(verbatim: "\(number)").font(.technicalSmall).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        // Re-render when the page rotates.
        .task(id: rotation) {
            thumbnail = page.thumbnail(of: NSSize(width: 320, height: 320), for: .cropBox)
        }
        .accessibilityLabel("Page \(number)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
