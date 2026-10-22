import AppKit
import ImageEngine
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
                .containerBackground(Theme.base, for: .window)
                .onAppear { appDelegate.attach(document) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") { document.presentOpenPanel() }
                    .keyboardShortcut("o")
                Button("Download from Link…") { document.linkDownload.isShowingSheet = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Home") { document.goHome() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .disabled(document.sourceURL == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Export…") { document.export() }
                    .keyboardShortcut("e")
                    .disabled(!document.canExport)
            }
        }

        Window("About DEX", id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

/// Receives files from Finder's "Open With" and drops on the Dock icon,
/// which can arrive before the window exists.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var document: ImageDocument?
    private var batch: [URL] = []
    private var batchTask: Task<Void, Never>?
    private lazy var services = FinderServices { [weak self] in self?.document }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }

    func attach(_ document: ImageDocument) {
        self.document = document
        scheduleBatch()
    }

    /// Finder and `open` can deliver several files as separate events, in
    /// any order, so events arriving close together are handled as one.
    func application(_ application: NSApplication, open urls: [URL]) {
        batch.append(contentsOf: urls)
        scheduleBatch()
    }

    private func scheduleBatch() {
        batchTask?.cancel()
        batchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let document, !batch.isEmpty else { return }
            let urls = batch
            batch = []
            await Self.open(urls, in: document)
        }
    }

    /// One file opens normally. Several: the largest becomes the base (so a
    /// logo lands on the photo, not the other way round) and the rest join
    /// Compose.
    private static func open(_ urls: [URL], in document: ImageDocument) async {
        var ordered = urls
        if urls.count > 1 {
            var areas: [URL: Int] = [:]
            for url in urls {
                let info = try? await ImageEngine.inspectAsync(url: url)
                areas[url] = info.map { $0.pixelWidth * $0.pixelHeight } ?? 0
            }
            if let base = urls.max(by: { areas[$0, default: 0] < areas[$1, default: 0] }) {
                ordered = [base] + urls.filter { $0 != base }
            }
        }
        await document.open(ordered[0])
        if ordered.count > 1 && document.audio == nil {
            document.tool = .compose
            await document.addImages(Array(ordered.dropFirst()))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
