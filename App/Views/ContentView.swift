import MediaModel
import SwiftUI

struct ContentView: View {
    @Bindable var document: ImageDocument
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if document.sourceURL == nil {
                DropZoneView(isTargeted: isDropTargeted, formats: document.writableFormats) {
                    document.presentOpenPanel()
                }
            } else {
                PreviewPane(document: document, isDropTargeted: isDropTargeted)
                    .inspector(isPresented: .constant(true)) {
                        InspectorView(document: document)
                            .inspectorColumnWidth(min: 300, ideal: 320, max: 380)
                    }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await document.open(url) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Open", systemImage: "folder") { document.presentOpenPanel() }
                    .help("Open an image (⌘O)")
            }
        }
        .navigationTitle(document.sourceURL?.lastPathComponent ?? "DEX")
        .confirmationDialog(
            "This export loses some information",
            isPresented: $document.isConfirmingLossyExport,
            titleVisibility: .visible
        ) {
            Button("Export Anyway") { document.presentSavePanel() }
            if let alternative = document.plan?.losslessAlternative {
                Button("Save as \(alternative.displayName) Instead (Lossless)") { document.useLosslessAlternative() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let plan = document.plan {
                Text(plan.notes.filter(\.isLoss).map { "• \($0)" }.joined(separator: "\n"))
            }
        }
    }
}
