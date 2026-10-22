import Downloader
import Foundation

/// One download at a time per connection.
final class DownloaderHandler: NSObject, DownloaderServiceProtocol, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private let downloader: LinkDownloader

    init(connection: NSXPCConnection) {
        self.connection = connection
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let tools = support.appendingPathComponent("DEX/Tools", isDirectory: true)
        downloader = LinkDownloader(toolFolder: tools)
    }

    func isToolInstalled(reply: @escaping @Sendable (Bool) -> Void) {
        reply(downloader.isToolInstalled)
    }

    func download(_ link: String, reply: @escaping @Sendable (String?, String?) -> Void) {
        guard let url = LinkDownloader.link(in: link) else {
            reply(nil, LinkDownloadError.notALink.description)
            return
        }
        let progress = ProgressSender(connection.remoteObjectProxy as? DownloaderProgressProtocol)
        let downloads = DownloaderService.stagingFolder
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let downloader = downloader
        let work = Task {
            do {
                let file = try await downloader.download(url, into: downloads) { phase in
                    switch phase {
                    case .settingUp: progress.send(0, 0)
                    case .updating: progress.send(1, 0)
                    case .downloading(let fraction): progress.send(2, fraction)
                    case .finishing: progress.send(3, 1)
                    case .converting(let fraction): progress.send(4, fraction)
                    }
                }
                reply(file.path, nil)
            } catch is CancellationError {
                reply(nil, nil)
            } catch {
                reply(nil, String(describing: error))
            }
        }
        lock.withLock { task = work }
    }

    func downloadVideo(_ link: String, format: String, convert: Bool, reply: @escaping @Sendable (String?, String?) -> Void) {
        guard let url = LinkDownloader.link(in: link), format.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            reply(nil, LinkDownloadError.notALink.description)
            return
        }
        let progress = ProgressSender(connection.remoteObjectProxy as? DownloaderProgressProtocol)
        let staging = DownloaderService.stagingFolder
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let downloader = downloader
        let work = Task {
            do {
                let file = try await downloader.downloadVideo(url, option: format, convert: convert, into: staging) { phase in
                    switch phase {
                    case .settingUp: progress.send(0, 0)
                    case .updating: progress.send(1, 0)
                    case .downloading(let fraction): progress.send(2, fraction)
                    case .finishing: progress.send(3, 1)
                    case .converting(let fraction): progress.send(4, fraction)
                    }
                }
                reply(file.path, nil)
            } catch is CancellationError {
                reply(nil, nil)
            } catch {
                reply(nil, String(describing: error))
            }
        }
        lock.withLock { task = work }
    }

    func info(_ link: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
        guard let url = LinkDownloader.link(in: link) else {
            reply(nil, LinkDownloadError.notALink.description)
            return
        }
        let downloader = downloader
        let work = Task {
            do {
                let info = try await downloader.info(url)
                reply(try JSONEncoder().encode(info), nil)
            } catch is CancellationError {
                reply(nil, nil)
            } catch {
                reply(nil, String(describing: error))
            }
        }
        lock.withLock { task = work }
    }

    func fetchModel(_ link: String, into file: FileHandle, reply: @escaping @Sendable (String?) -> Void) {
        let progress = ProgressSender(connection.remoteObjectProxy as? DownloaderProgressProtocol)
        let work = Task {
            do {
                try await ModelFetcher.fetch(link, into: file) { progress.send(2, $0) }
                reply(nil)
            } catch is CancellationError {
                reply("Cancelled.")
            } catch {
                reply(String(describing: error))
            }
            try? file.close()
        }
        lock.withLock { task = work }
    }

    func cancel() {
        lock.withLock { task?.cancel() }
    }
}

/// The app's progress proxy; XPC proxies may be messaged from any thread.
struct ProgressSender: @unchecked Sendable {
    let proxy: DownloaderProgressProtocol?

    init(_ proxy: DownloaderProgressProtocol?) { self.proxy = proxy }

    func send(_ kind: Int, _ fraction: Double) { proxy?.phase(kind, fraction: fraction) }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: DownloaderServiceProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: DownloaderProgressProtocol.self)
        let handler = DownloaderHandler(connection: connection)
        connection.exportedObject = handler
        connection.invalidationHandler = { handler.cancel() }
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
