import MediaModel
import SwiftUI

struct ContentView: View {
    @Bindable var document: ImageDocument
    @State private var isDropTargeted = false
    @State private var tool: Tool? = .convert

    var body: some View {
        ZStack {
            Backdrop()

            if document.sourceURL == nil {
                DropZoneView(isTargeted: isDropTargeted, formats: document.writableFormats) {
                    document.presentOpenPanel()
                }
            } else {
                Workspace(document: document, tool: $tool)

                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.ember, lineWidth: 3)
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await document.open(url) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .navigationTitle(document.sourceURL?.lastPathComponent ?? "DEX")
        .preferredColorScheme(.dark)
    }
}
