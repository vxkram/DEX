import AppKit
import ImageEngine
import JobSystem
import MediaModel

/// Finder right-click → Services → DEX ▸ …  (declared as NSServices in
/// Info.plist). Quick conversions write next to the originals, never
/// overwriting, then select the results in Finder.
@MainActor
final class FinderServices: NSObject {
    private let document: () -> ImageDocument?

    init(document: @escaping () -> ImageDocument?) {
        self.document = document
    }

    /// NSMessage "convertImages"; NSUserData is the target format, or "pdf".
    @objc func convertImages(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = fileURLs(from: pasteboard)
        guard !urls.isEmpty, let userData else { return }
        Task {
            if userData == "pdf" {
                await combineIntoPDF(urls)
            } else if let format = ImageFormat(rawValue: userData) {
                await convert(urls, to: format)
            }
        }
    }

    /// NSMessage "openImages".
    @objc func openImages(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = fileURLs(from: pasteboard)
        guard let first = urls.first, let document = document() else { return }
        NSApp.activate()
        Task {
            await document.open(first)
            if urls.count > 1 && document.audio == nil {
                document.tool = .compose
                await document.addImages(Array(urls.dropFirst()))
            }
        }
    }

    // MARK: - Work

    private func convert(_ urls: [URL], to format: ImageFormat) async {
        var outputs: [URL] = []
        var failures: [String] = []
        for url in urls {
            guard let folder = await FolderAccess.shared.writableFolder(containing: url) else { return }
            defer { folder.stopAccessingSecurityScopedResource() }
            do {
                let (_, plan) = try ImageEngine.plan(url, ConvertRequest(target: format))
                let destination = SafeOutput.defaultDestination(for: url, pathExtension: format.preferredFileExtension)
                try await ImageEngine.convert(url, plan: plan, to: destination)
                outputs.append(destination)
            } catch {
                failures.append("\(url.lastPathComponent): \(error)")
            }
        }
        finish(outputs: outputs, failures: failures)
    }

    private func combineIntoPDF(_ urls: [URL]) async {
        let images = urls.filter { !PDFEngine.isPDF($0) }
        guard let first = images.first, let folder = await FolderAccess.shared.writableFolder(containing: first) else { return }
        defer { folder.stopAccessingSecurityScopedResource() }
        let destination = SafeOutput.defaultDestination(for: first, pathExtension: "pdf")
        do {
            try await PDFEngine.makePDF(
                from: images.map { PDFEngine.PageImage(url: $0) }, pageSize: .fitImage, margin: 0,
                title: first.deletingPathExtension().lastPathComponent, to: destination
            )
            finish(outputs: [destination], failures: [])
        } catch {
            finish(outputs: [], failures: ["\(error)"])
        }
    }

    private func finish(outputs: [URL], failures: [String]) {
        if !outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        }
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = failures.count == 1 ? "One image couldn't be converted" : "\(failures.count) images couldn't be converted"
            alert.informativeText = failures.prefix(5).joined(separator: "\n")
            NSApp.activate()
            alert.runModal()
        }
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

/// Remembers folders the user allowed DEX to save into. The sandbox
/// only allows writing where the user chose, so the first quick convert in
/// a folder asks once; a security-scoped bookmark keeps the permission.
@MainActor
final class FolderAccess {
    static let shared = FolderAccess()
    private let key = "FolderAccess.bookmarks"

    /// A folder URL with access started (caller stops it), or nil if the
    /// user declined.
    func writableFolder(containing file: URL) async -> URL? {
        let folder = file.deletingLastPathComponent().standardizedFileURL
        if let url = resolved(folder), url.startAccessingSecurityScopedResource() {
            if FileManager.default.isWritableFile(atPath: url.path) { return url }
            url.stopAccessingSecurityScopedResource()
        }
        guard let granted = askForAccess(to: folder) else { return nil }
        guard granted.startAccessingSecurityScopedResource() else { return nil }
        return granted
    }

    private func resolved(_ folder: URL) -> URL? {
        guard let data = bookmarks[folder.path] else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale { store(url) }
        return url
    }

    private func askForAccess(to folder: URL) -> URL? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.directoryURL = folder
        panel.prompt = "Allow"
        panel.message = "Allow DEX to save converted images in “\(folder.lastPathComponent)”. It will remember this folder."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        store(url)
        return url
    }

    private func store(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return
        }
        var all = bookmarks
        all[url.standardizedFileURL.path] = data
        UserDefaults.standard.set(all, forKey: key)
    }

    private var bookmarks: [String: Data] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
    }
}
