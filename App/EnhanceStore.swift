import Foundation
import ImageEngine
import MediaModel
import Observation

/// The Enhance models on this Mac: which are installed, downloading them
/// through the Downloader service (the app itself has no network access),
/// and removing them.
@MainActor
@Observable
final class EnhanceStore {
    private(set) var installed: Set<EnhanceModel> = []
    /// Models being downloaded, with progress 0…1.
    private(set) var downloading: [EnhanceModel: Double] = [:]
    var error: String?

    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private lazy var progress = ModelProgressReceiver { [weak self] fraction in
        Task { @MainActor in
            guard let self, let model = self.current else { return }
            self.downloading[model] = fraction
        }
    }
    @ObservationIgnored private var current: EnhanceModel?
    @ObservationIgnored private var queue: [EnhanceModel] = []

    init() { refresh() }

    func refresh() {
        installed = Set(EnhanceModel.allCases.filter(EnhanceModels.isInstalled))
    }

    func isInstalled(_ model: EnhanceModel) -> Bool { installed.contains(model) }

    func missing(_ models: [EnhanceModel]) -> [EnhanceModel] { models.filter { !installed.contains($0) } }

    var isDownloading: Bool { !downloading.isEmpty }

    /// Downloads the given models one after another.
    func download(_ models: [EnhanceModel]) {
        error = nil
        for model in models where !installed.contains(model) && downloading[model] == nil {
            downloading[model] = 0
            queue.append(model)
        }
        next()
    }

    func cancel() {
        (connection?.remoteObjectProxy as? DownloaderServiceProtocol)?.cancel()
        queue = []
        downloading = [:]
        current = nil
    }

    func remove(_ model: EnhanceModel) {
        EnhanceModels.remove(model)
        refresh()
    }

    private func next() {
        guard current == nil, !queue.isEmpty else { return }
        let model = queue.removeFirst()
        current = model
        let folder = EnhanceModels.folder
        let zip = folder.appendingPathComponent(model.rawValue + ".download.zip")
        let handle: FileHandle
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: zip.path, contents: nil)
            handle = try FileHandle(forWritingTo: zip)
        } catch {
            finish(model, failure: "Couldn't make room for the \(model.title) model: \(error.localizedDescription)")
            return
        }
        guard let proxy = proxy() else { return }
        proxy.fetchModel(model.downloadURL.absoluteString, into: handle) { [weak self] failure in
            try? handle.close()
            Task { @MainActor in
                guard let self else { return }
                if let failure {
                    try? FileManager.default.removeItem(at: zip)
                    self.finish(model, failure: failure)
                    return
                }
                do {
                    try await EnhanceModels.install(model, from: zip)
                    self.finish(model, failure: nil)
                } catch {
                    self.finish(model, failure: String(describing: error))
                }
            }
        }
    }

    private func finish(_ model: EnhanceModel, failure: String?) {
        downloading[model] = nil
        current = nil
        if let failure {
            error = failure
            for queued in queue { downloading[queued] = nil }
            queue = []
        }
        refresh()
        next()
    }

    // MARK: - Service

    private func proxy() -> DownloaderServiceProtocol? {
        service().remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in
                guard let self, let model = self.current else { return }
                self.finish(model, failure: "The downloader stopped unexpectedly: \(error.localizedDescription)")
            }
        } as? DownloaderServiceProtocol
    }

    private func service() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(serviceName: DownloaderService.name)
        connection.remoteObjectInterface = NSXPCInterface(with: DownloaderServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: DownloaderProgressProtocol.self)
        connection.exportedObject = progress
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.resume()
        self.connection = connection
        return connection
    }
}

/// Receives download progress from the service (on an XPC thread).
private final class ModelProgressReceiver: NSObject, DownloaderProgressProtocol, @unchecked Sendable {
    private let update: @Sendable (Double) -> Void

    init(_ update: @escaping @Sendable (Double) -> Void) { self.update = update }

    func phase(_ kind: Int, fraction: Double) {
        if kind == 2 { update(fraction) }
    }
}
