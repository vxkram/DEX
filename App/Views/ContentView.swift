import MediaModel
import SwiftUI

struct ContentView: View {
    @Bindable var document: ImageDocument
    @State private var isDropTargeted = false
    @State private var pointer = Pointer()

    var body: some View {
        ZStack {
            Backdrop(pointer: pointer)

            if document.linkDownload.isPageVisible {
                LinkPage(download: document.linkDownload) { await document.open($0) }
            } else if let audio = document.audio {
                AudioWorkspace(document: document, audio: audio)

                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.ember, lineWidth: 3)
                        .padding(10)
                        .allowsHitTesting(false)
                }
            } else if document.sourceURL == nil {
                DropZoneView(isTargeted: isDropTargeted, formats: document.writableFormats,
                             download: document.linkDownload) {
                    document.presentOpenPanel()
                }
            } else {
                Workspace(document: document)

                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.ember, lineWidth: 3)
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { pointer.size = $0 }
        .onContinuousHover { pointer.update($0) }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            // In Compose, dropped images join the composition instead of
            // replacing the photo.
            if document.audio != nil {
                Task { await document.open(url) }
            } else if document.tool == .compose && document.sourceURL != nil && !document.isPDFDocument {
                Task { await document.addImages(urls) }
            } else if document.tool == .pdf && document.sourceURL != nil && !document.isPDFDocument {
                Task { await document.addPDFImages(urls) }
            } else {
                Task { await document.open(url) }
            }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .navigationTitle(document.sourceURL?.lastPathComponent ?? "DEX")
        .sheet(isPresented: Bindable(document.linkDownload).isShowingSheet) {
            LinkDownloadSheet(download: document.linkDownload)
        }
        .sheet(isPresented: $document.needsPDFPassword) {
            PDFPasswordSheet(document: document)
        }
        .preferredColorScheme(.dark)
    }
}
