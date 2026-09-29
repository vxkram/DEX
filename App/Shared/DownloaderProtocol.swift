import Foundation

/// The DEX Downloader XPC service: runs yt-dlp outside the app's
/// sandbox (a sandboxed app can't launch programs it downloaded). The app
/// itself never touches the network. See docs/adr/0006-link-download.md.
@objc protocol DownloaderServiceProtocol {
    /// Looks the link up: replies with a JSON-encoded `LinkInfo`, or an
    /// error message.
    func info(_ link: String, reply: @escaping @Sendable (Data?, String?) -> Void)
    /// Downloads a link's audio (YouTube's AAC, as it is) into
    /// `DownloaderService.stagingFolder`. Replies with the file's path, or
    /// an error message.
    func download(_ link: String, reply: @escaping @Sendable (String?, String?) -> Void)
    /// Downloads the chosen video stream plus the AAC audio and joins them
    /// into one MP4 in `DownloaderService.stagingFolder`. `convert` turns an
    /// AV1 picture into H.264 on the way.
    func downloadVideo(_ link: String, format: String, convert: Bool, reply: @escaping @Sendable (String?, String?) -> Void)
    func cancel()
    func isToolInstalled(reply: @escaping @Sendable (Bool) -> Void)
}

/// Progress, sent back from the service to the app.
@objc protocol DownloaderProgressProtocol {
    /// kind: 0 setting up, 1 updating, 2 downloading, 3 finishing, 4 converting.
    func phase(_ kind: Int, fraction: Double)
}

enum DownloaderService {
    static let name = "com.dex.app.Downloader"

    /// Where downloads land before the app saves them in the chosen format:
    /// inside ~/Downloads (which the sandboxed app may read), hidden.
    static var stagingFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".DEX downloading", isDirectory: true)
    }
}
