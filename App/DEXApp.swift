import AppKit
import SwiftUI

@main
struct DEXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var document = ImageDocument()

    var body: some Scene {
        Window("DEX", id: "main") {
            ContentView(document: document)
                .frame(minWidth: 900, minHeight: 600)
                .tint(Theme.ember)
                .onAppear { appDelegate.attach(document) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { document.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Export…") { document.presentSavePanel() }
                    .keyboardShortcut("e")
                    .disabled(!document.canExport)
            }
        }
    }
}

/// Receives files from Finder's "Open With" and drops on the Dock icon,
/// which can arrive before the window exists.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var document: ImageDocument?
    private var pending: URL?

    func attach(_ document: ImageDocument) {
        self.document = document
        if let pending {
            self.pending = nil
            Task { await document.open(pending) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let document {
            Task { await document.open(url) }
        } else {
            pending = url
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
