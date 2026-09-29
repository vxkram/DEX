import ImageEngine
import MediaModel
import SwiftUI

/// PDF → images for an open PDF; images → PDF for an open image.
struct PDFPanel: View {
    @Bindable var document: ImageDocument

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if document.isPDFDocument {
                        PDFToImages(document: document)
                    } else {
                        ImagesToPDF(document: document)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
            PDFFooter(document: document)
        }
    }
}

// MARK: - PDF → images

private struct PDFToImages: View {
    @Bindable var document: ImageDocument

    var body: some View {
        if let info = document.pdfInfo {
            VStack(alignment: .leading, spacing: 8) {
                PanelSectionHeader("Pages")
                HStack {
                    Text(verbatim: "\(document.selectedPages.count) of \(info.pageCount) selected")
                        .font(.technical)
                    Spacer()
                    Button("All") { document.selectedPages = Set(1...info.pageCount) }
                        .buttonStyle(.link).tint(Theme.ember)
                    Button("None") { document.selectedPages = [] }
                        .buttonStyle(.link).tint(Theme.ember)
                }
                Explanation("Click pages in the preview to choose which ones to export.")
            }

            VStack(alignment: .leading, spacing: 8) {
                PanelSectionHeader("Resolution")
                HStack(spacing: 6) {
                    ForEach([(72.0, "Screen"), (150.0, "Standard"), (300.0, "Print"), (600.0, "Max")], id: \.0) { dpi, use in
                        TwoLineChip(title: "\(Int(dpi))", subtitle: use, isSelected: document.rasterDPI == dpi) {
                            document.rasterDPI = dpi
                        }
                    }
                }
                if let first = info.pageSizes.first {
                    let scale = document.rasterDPI / 72
                    Text(verbatim: "Page 1 → \(Int((first.width * scale).rounded())) × \(Int((first.height * scale).rounded())) px")
                        .font(.technicalSmall)
                        .foregroundStyle(.secondary)
                }
                Explanation("Dots per inch: higher means sharper text and larger files. 150 suits screens, 300 suits printing.")
            }

            VStack(alignment: .leading, spacing: 8) {
                PanelSectionHeader("Format")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach([ImageFormat.png, .jpeg, .webp, .heic, .avif, .tiff].filter(document.writableFormats.contains), id: \.self) { format in
                        Chip(title: format.displayName, isSelected: document.rasterFormat == format) {
                            document.rasterFormat = format
                        }
                    }
                }
                if document.rasterFormat.hasLossyMode {
                    LabeledSlider(title: "Quality", value: document.rasterQuality, range: 0.5...1,
                                  display: document.rasterFormat == .webp && document.rasterQuality >= 0.99
                                      ? "Lossless" : "\(Int((document.rasterQuality * 100).rounded()))") {
                        document.rasterQuality = $0
                    }
                } else {
                    Explanation("\(document.rasterFormat.displayName) is lossless: text and lines stay perfectly crisp.")
                }
            }
        }
    }
}

// MARK: - Images → PDF

private struct ImagesToPDF: View {
    @Bindable var document: ImageDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSectionHeader("Pages (in order)")
            if let info = document.info {
                PageRow(name: info.fileName, detail: document.hasEdits || document.composition != nil ? "with your edits" : "page 1",
                        preview: document.preview?.cgImage)
            }
            ForEach(Array(document.pdfImages.enumerated()), id: \.element.url) { index, image in
                PageRow(name: image.info.fileName, detail: "page \(index + 2)", preview: document.extraPreviews[image.url]?.cgImage,
                        moveUp: index > 0 ? { document.movePDFImage(at: index, by: -1) } : nil,
                        moveDown: index < document.pdfImages.count - 1 ? { document.movePDFImage(at: index, by: 1) } : nil,
                        remove: { document.removePDFImage(image) })
            }
            Button {
                document.presentAddPDFImagesPanel()
            } label: {
                Label("Add Pages…", systemImage: "plus")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glass)
            Explanation("One image per page, any format. JPEGs go in untouched (no re-encoding); location data is removed.")
        }

        VStack(alignment: .leading, spacing: 8) {
            PanelSectionHeader("Non-JPEG pages")
            HStack(spacing: 6) {
                TwoLineChip(title: "Lossless", subtitle: "exact, larger", isSelected: document.pdfImageQuality == nil) {
                    document.pdfImageQuality = nil
                }
                TwoLineChip(title: "Smaller", subtitle: "JPEG 90", isSelected: document.pdfImageQuality != nil) {
                    document.pdfImageQuality = 0.9
                }
            }
            Explanation("PDFs can't hold HEIC, PNG or WebP as-is: Lossless is exact but big, Smaller uses JPEG 90.")
            PDFSizeLine(document: document)
        }

        VStack(alignment: .leading, spacing: 8) {
            PanelSectionHeader("Page size")
            HStack(spacing: 6) {
                TwoLineChip(title: "Fit", subtitle: "image size", isSelected: document.pdfPageSize == .fitImage) { document.pdfPageSize = .fitImage }
                TwoLineChip(title: "A4", subtitle: "210 × 297 mm", isSelected: document.pdfPageSize == .a4) { document.pdfPageSize = .a4 }
                TwoLineChip(title: "Letter", subtitle: "8.5 × 11 in", isSelected: document.pdfPageSize == .letter) { document.pdfPageSize = .letter }
            }
            if document.pdfPageSize != .fitImage {
                LabeledSlider(title: "Margin", value: document.pdfMargin, range: 0...72,
                              display: "\(Int((document.pdfMargin / 72 * 25.4).rounded())) mm") {
                    document.pdfMargin = $0.rounded()
                }
                Explanation("Pages turn landscape automatically for wide images.")
            }
        }
    }
}

private struct PDFSizeLine: View {
    let document: ImageDocument

    var body: some View {
        HStack(spacing: 6) {
            if let estimate = document.pdfEstimate, estimate.key == document.pdfEstimateKey, let bytes = estimate.bytes {
                Image(systemName: "doc").foregroundStyle(.secondary)
                Text(verbatim: "PDF ≈ " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.technical)
            } else {
                ProgressView().controlSize(.mini)
                Text("Measuring PDF size…").font(.technicalSmall).foregroundStyle(.secondary)
            }
        }
        .task(id: document.pdfEstimateKey) { await document.refreshPDFEstimate() }
    }
}

private struct PageRow: View {
    let name: String
    let detail: String
    let preview: CGImage?
    var moveUp: (() -> Void)?
    var moveDown: (() -> Void)?
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let preview {
                    Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.white.opacity(0.08))
                }
            }
            .frame(width: 30, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.technicalSmall).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if moveUp != nil || moveDown != nil {
                Button("Move up", systemImage: "chevron.up") { moveUp?() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(moveUp == nil)
                Button("Move down", systemImage: "chevron.down") { moveDown?() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(moveDown == nil)
            }
            if let remove { DismissButton(action: remove) }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.04)))
    }
}

struct TwoLineChip: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title).font(.system(.caption, design: .monospaced, weight: .semibold))
                Text(subtitle).font(.caption2).foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .foregroundStyle(isSelected ? .white : .primary)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? Theme.ember : .white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(isSelected ? 0 : 0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Footer

private struct PDFFooter: View {
    let document: ImageDocument

    var body: some View {
        VStack(spacing: 10) {
            switch document.exportState {
            case .running(let fraction):
                HStack {
                    ProgressView(value: fraction).tint(Theme.ember)
                    Button("Cancel", systemImage: "xmark.circle.fill") { document.cancelExport() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            case .saved(let url):
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(document.isPDFDocument ? "Pages exported" : url.lastPathComponent)
                        .font(.technicalSmall).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") { document.revealInFinder(url) }
                        .buttonStyle(.link).tint(Theme.ember)
                    DismissButton { document.dismissExportStatus() }
                }
                .font(.callout)
            case .failed(let message):
                HStack(alignment: .top) {
                    Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    DismissButton { document.dismissExportStatus() }
                }
            case .idle:
                EmptyView()
            }

            Button {
                if document.isPDFDocument { document.exportPagesToFolder() } else { document.presentPDFSavePanel() }
            } label: {
                Text(document.isPDFDocument
                     ? "Export \(document.selectedPages.count) Page\(document.selectedPages.count == 1 ? "" : "s")…"
                     : "Save as PDF…")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.ember)
            .controlSize(.large)
            .disabled(document.isExporting || (document.isPDFDocument && document.selectedPages.isEmpty))
        }
        .padding(16)
    }
}

// MARK: - Page grid (preview area for PDFs)

struct PageGrid: View {
    @Bindable var document: ImageDocument

    var body: some View {
        if let info = document.pdfInfo {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 18)], spacing: 18) {
                    ForEach(1...info.pageCount, id: \.self) { page in
                        PageTile(page: page, size: info.pageSizes[page - 1], thumbnail: document.pageThumbnails[page],
                                 isSelected: document.selectedPages.contains(page)) {
                            document.togglePage(page)
                        }
                    }
                }
                .padding(24)
            }
            .scrollIndicators(.automatic)
        } else if document.needsPDFPassword {
            ContentUnavailableView("Password required", systemImage: "lock.fill",
                                   description: Text("This PDF is protected."))
        } else {
            ProgressView().controlSize(.large)
        }
    }
}

private struct PageTile: View {
    let page: Int
    let size: CGSize
    let thumbnail: PDFEngine.CGImageBox?
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(decorative: thumbnail.image, scale: 1).resizable().interpolation(.high)
                    } else {
                        Rectangle().fill(.white.opacity(0.9)).overlay(ProgressView().controlSize(.small))
                    }
                }
                .aspectRatio(size.width / max(size.height, 1), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                .opacity(isSelected ? 1 : 0.45)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.ember : .white.opacity(0.8))
                    .background(Circle().fill(.black.opacity(0.35)))
                    .padding(6)
            }
            Text(verbatim: "\(page)").font(.technicalSmall).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityLabel("Page \(page)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Asks for the password of a protected PDF.
struct PDFPasswordSheet: View {
    let document: ImageDocument
    @State private var password = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("This PDF is password-protected", systemImage: "lock.fill").font(.headline)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(unlock)
            if let error = document.pdfPasswordError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Unlock", action: unlock)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        document.unlockPDF(with: password)
    }
}
