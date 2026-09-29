import AudioTagging
import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import JobSystem
import MediaModel

public enum LinkDownloadError: Error, Equatable, CustomStringConvertible {
    case notALink
    case toolUnavailable(String)
    case checksumMismatch
    case failed(String)

    public var description: String {
        switch self {
        case .notALink: "That doesn't look like a YouTube link."
        case .toolUnavailable(let detail): "The downloader couldn't be set up: \(detail)."
        case .checksumMismatch: "The downloaded yt-dlp didn't match its published checksum, so it wasn't used."
        case .failed(let detail): detail
        }
    }
}

/// One video quality DEX can save: a video-only MP4 stream (AV1 or
/// H.264) that gets joined with the AAC audio.
public struct VideoOption: Codable, Sendable, Hashable, Identifiable {
    public var formatID: String
    public var width: Int
    public var height: Int
    public var fps: Int
    /// "AV1" or "H.264".
    public var codec: String
    public var kbps: Int
    public var isHDR: Bool
    /// Video plus audio, when YouTube says (estimated for conversions).
    public var bytes: Int64?
    /// Made by converting YouTube's AV1 stream to H.264 on this Mac
    /// (YouTube has no H.264 this size).
    public var isConverted: Bool = false

    public var id: String { formatID + (isConverted ? "-h264" : "") }
    public var isH264: Bool { codec == "H.264" }

    /// "2160p60", "1080p".
    public var label: String { "\(height)p" + (fps > 30 ? "\(fps)" : "") }

    public var nickname: String? {
        switch height {
        case 4320...: "8K"
        case 2160...: "4K"
        case 1440...: "2K"
        case 1080...: "Full HD"
        case 720...: "HD"
        default: nil
        }
    }

    public init(formatID: String, width: Int, height: Int, fps: Int, codec: String, kbps: Int, isHDR: Bool, bytes: Int64?) {
        self.formatID = formatID
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec
        self.kbps = kbps
        self.isHDR = isHDR
        self.bytes = bytes
    }
}

/// What a link points to, for the format page.
public struct LinkInfo: Codable, Sendable, Equatable {
    public var title: String
    public var artist: String?
    public var album: String?
    /// Seconds.
    public var duration: Double?
    /// The thumbnail as JPEG.
    public var thumbnail: Data?
    /// Bit rate of the AAC stream that will be downloaded, kbit/s.
    public var aacKbps: Int?
    /// Video qualities, best first: per resolution, frame rate and HDR,
    /// the AV1 stream and the H.264 one where they exist.
    public var videoOptions: [VideoOption]
    /// The tallest picture YouTube has only as VP9 (which macOS can't
    /// play), when it's taller than every option above.
    public var vp9OnlyHeight: Int?

    public init(title: String, artist: String? = nil, album: String? = nil, duration: Double? = nil,
                thumbnail: Data? = nil, aacKbps: Int? = nil, videoOptions: [VideoOption] = [], vp9OnlyHeight: Int? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.thumbnail = thumbnail
        self.aacKbps = aacKbps
        self.videoOptions = videoOptions
        self.vp9OnlyHeight = vp9OnlyHeight
    }
}

public enum LinkDownloadPhase: Sendable, Equatable {
    case settingUp
    case updating
    case downloading(Double)
    case converting(Double)
    case finishing
}

/// Downloads the audio of a YouTube video with yt-dlp, which is fetched
/// from its official GitHub release on first use (and verified against the
/// release's SHA-256 list), kept in the app's own folder, and updated when
/// YouTube changes. See docs/adr/0006-link-download.md.
///
/// It takes the best audio stream macOS can open *as it is*: YouTube's
/// AAC in M4A. Nothing is re-encoded.
public struct LinkDownloader: Sendable {
    public let toolFolder: URL

    static let releaseBase = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/")!
    static let binaryName = "yt-dlp_macos"
    /// Best AAC stream; the second choice catches AAC in other containers.
    static let format = "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]"

    public init(toolFolder: URL) {
        self.toolFolder = toolFolder
    }

    public var toolURL: URL { toolFolder.appendingPathComponent(Self.binaryName) }
    public var isToolInstalled: Bool { FileManager.default.isExecutableFile(atPath: toolURL.path) }

    /// A YouTube (or YouTube Music) link in the text, if there is one.
    public static func link(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), let host = url.host()?.lowercased(),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { return nil }
        let hosts = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be"]
        guard hosts.contains(host) else { return nil }
        if host.hasSuffix("youtu.be") { return url.path().count > 1 ? url : nil }
        let path = url.path()
        let hasVideo = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "v" && !($0.value ?? "").isEmpty } ?? false
        return hasVideo || path.hasPrefix("/shorts/") || path.hasPrefix("/live/") ? url : nil
    }

    // MARK: - Look up

    /// Title, channel, length, thumbnail and AAC quality, without
    /// downloading the audio.
    public func info(_ link: URL) async throws -> LinkInfo {
        if !isToolInstalled { try await installTool() }
        do {
            return try await lookUp(link)
        } catch let error as LinkDownloadError {
            guard case .failed = error, (try? await update()) == true else { throw error }
            return try await lookUp(link)
        }
    }

    private func lookUp(_ link: URL) async throws -> LinkInfo {
        var json: String?
        var lastError = ""
        let status = try await Self.execute(toolURL, ["-J", "--no-playlist", "--no-warnings", link.absoluteString]) { line in
            if line.hasPrefix("{") { json = line }
            if line.hasPrefix("ERROR:") { lastError = line }
        }
        try Task.checkCancellation()
        guard status == 0, let json, var info = Self.parseInfo(Data(json.utf8)) else {
            throw LinkDownloadError.failed(Self.explain(lastError))
        }
        if let address = Self.thumbnailURL(Data(json.utf8)),
           let (data, _) = try? await URLSession.shared.data(from: address) {
            info.thumbnail = Self.jpeg(data)
        }
        return info
    }

    static func parseInfo(_ data: Data) -> LinkInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func string(_ keys: String...) -> String? {
            keys.lazy.compactMap { object[$0] as? String }.first { !$0.isEmpty }
        }
        guard let title = string("track", "title") else { return nil }
        let formats = object["formats"] as? [[String: Any]] ?? []
        let aac = formats.filter {
            ($0["acodec"] as? String ?? "").hasPrefix("mp4a") && ($0["vcodec"] as? String ?? "none") == "none"
        }
        let kbps = aac.compactMap { ($0["abr"] as? Double) ?? ($0["tbr"] as? Double) }.max()
        let aacBytes = aac.compactMap(Self.size).max()
        let options = Self.videoOptions(formats, audioBytes: aacBytes, duration: object["duration"] as? Double)
        let tallest = options.map(\.height).max() ?? 0
        let vp9 = formats.filter { ($0["vcodec"] as? String ?? "").hasPrefix("vp") }.compactMap { $0["height"] as? Int }.max()
        return LinkInfo(title: title, artist: string("artist", "creator", "uploader", "channel"), album: string("album"),
                        duration: object["duration"] as? Double, aacKbps: kbps.map { Int($0.rounded()) },
                        videoOptions: options, vp9OnlyHeight: vp9.flatMap { $0 > tallest ? $0 : nil })
    }

    /// Video-only MP4 streams over plain HTTPS (not HLS), AV1 or H.264,
    /// the highest bit rate of each kind, best first.
    static func videoOptions(_ formats: [[String: Any]], audioBytes: Int64?, duration: Double? = nil) -> [VideoOption] {
        var best: [String: VideoOption] = [:]
        for format in formats {
            let vcodec = format["vcodec"] as? String ?? "none"
            guard (format["acodec"] as? String ?? "none") == "none", format["ext"] as? String == "mp4",
                  (format["protocol"] as? String ?? "https") == "https",
                  let id = format["format_id"] as? String, let height = format["height"] as? Int, height > 0
            else { continue }
            let codec: String
            if vcodec.hasPrefix("av01") { codec = "AV1" } else if vcodec.hasPrefix("avc1") { codec = "H.264" } else { continue }
            let fps = Int(((format["fps"] as? Double) ?? 30).rounded())
            let hdr = !["SDR", nil].contains(format["dynamic_range"] as? String)
            let kbps = Int(((format["tbr"] as? Double) ?? (format["vbr"] as? Double) ?? 0).rounded())
            let option = VideoOption(formatID: id, width: format["width"] as? Int ?? 0, height: height, fps: fps, codec: codec,
                                     kbps: kbps, isHDR: hdr, bytes: Self.size(format).map { $0 + (audioBytes ?? 0) })
            let key = "\(height)-\(fps)-\(hdr)-\(codec)"
            if (best[key]?.kbps ?? -1) < kbps { best[key] = option }
        }
        // Sizes above YouTube's tallest H.264 can be made by converting the
        // AV1 stream (SDR only: H.264 here is 8-bit).
        let tallestH264 = best.values.filter(\.isH264).map(\.height).max() ?? 0
        let converted = best.values.filter { !$0.isH264 && !$0.isHDR && $0.height > tallestH264 }.map { source in
            var option = source
            option.codec = "H.264"
            option.isConverted = true
            option.kbps = VideoConverter.bitRate(height: source.height, fps: source.fps)
            if let duration = duration {
                option.bytes = Int64(duration * Double(option.kbps) * 125) + (audioBytes ?? 0)
            }
            return option
        }
        return (best.values + converted).sorted {
            ($0.height, $0.fps, $0.isHDR ? 1 : 0, $0.isConverted ? 0 : 1, $0.isH264 ? 0 : 1)
                > ($1.height, $1.fps, $1.isHDR ? 1 : 0, $1.isConverted ? 0 : 1, $1.isH264 ? 0 : 1)
        }
    }

    private static func size(_ format: [String: Any]) -> Int64? {
        ((format["filesize"] as? Double) ?? (format["filesize_approx"] as? Double)).map { Int64($0) }
            ?? (format["filesize"] as? Int).map(Int64.init) ?? (format["filesize_approx"] as? Int).map(Int64.init)
    }

    static func thumbnailURL(_ data: Data) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let address = object["thumbnail"] as? String
        else { return nil }
        return URL(string: address)
    }

    // MARK: - Download

    /// Downloads into `folder` and returns the file. Updates yt-dlp and
    /// retries once if the first attempt fails (usually a YouTube change).
    public func download(
        _ link: URL, into folder: URL, phase: @escaping @Sendable (LinkDownloadPhase) -> Void
    ) async throws -> URL {
        if !isToolInstalled {
            phase(.settingUp)
            try await installTool()
        }
        do {
            return try await run(link, into: folder, phase: phase)
        } catch let error as LinkDownloadError {
            guard case .failed = error else { throw error }
            phase(.updating)
            guard (try? await update()) == true else { throw error }
            return try await run(link, into: folder, phase: phase)
        }
    }

    private func run(_ link: URL, into folder: URL, phase: @escaping @Sendable (LinkDownloadPhase) -> Void) async throws -> URL {
        try clearQuarantine()
        // Work in a private staging folder, then move the finished file in
        // under a name that doesn't replace anything.
        let staging = toolFolder.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let arguments = [
            "--no-playlist", "--no-warnings", "--newline", "--no-mtime", "--no-part",
            "-f", Self.format,
            "-P", staging.path,
            "-o", "%(title).180B.%(ext)s",
            "--write-thumbnail",
            "--progress-template", "download:DEX %(progress._percent_str)s",
            "--print", "after_move:DEX-FILE %(filepath)s",
            "--print", "after_move:DEX-TITLE %(track,title)s",
            "--print", "after_move:DEX-ARTIST %(artist,creator,uploader)s",
            "--print", "after_move:DEX-ALBUM %(album)s",
            link.absoluteString,
        ]
        var file: String?
        var fields: [String: String] = [:]
        var lastError = ""
        let status = try await Self.execute(toolURL, arguments) { line in
            if let fraction = Self.progress(in: line) { phase(.downloading(fraction)) }
            for key in ["FILE", "TITLE", "ARTIST", "ALBUM"] where line.hasPrefix("DEX-\(key) ") {
                let value = String(line.dropFirst("DEX-\(key) ".count))
                if value != "NA" && !value.isEmpty { fields[key] = value }
            }
            if line.hasPrefix("ERROR:") { lastError = line }
        }
        file = fields["FILE"]
        try Task.checkCancellation()
        guard status == 0, let file else {
            throw LinkDownloadError.failed(Self.explain(lastError))
        }
        phase(.finishing)
        let downloaded = URL(fileURLWithPath: file)
        // The video's title, channel and thumbnail become the file's tags;
        // the audio is only re-muxed (passthrough), never re-encoded.
        let tags = AudioTags(title: fields["TITLE"], artist: fields["ARTIST"], album: fields["ALBUM"],
                             artwork: Self.thumbnail(in: staging))
        if !tags.isEmpty { try? await AudioTagging.write(tags, to: downloaded, format: .aac) }
        let destination = SafeOutput.defaultDestination(
            for: folder.appendingPathComponent(downloaded.lastPathComponent), pathExtension: downloaded.pathExtension
        )
        try FileManager.default.moveItem(at: downloaded, to: destination)
        return destination
    }

    /// The thumbnail yt-dlp saved next to the audio, as JPEG (YouTube's
    /// are usually WebP, which few players show as cover art).
    static func thumbnail(in folder: URL) -> Artwork? {
        let images = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { ["webp", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) } ?? []
        guard let url = images.first, let data = try? Data(contentsOf: url), let jpeg = jpeg(data) else { return nil }
        return Artwork(data: jpeg)
    }

    /// Any image ImageIO reads (YouTube's are WebP), as JPEG.
    static func jpeg(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    // MARK: - Video

    /// Downloads the chosen video stream and the AAC audio, then joins them
    /// into one MP4 in `folder` (no re-encoding). Returns the file.
    public func downloadVideo(
        _ link: URL, option: String, convert: Bool = false, into folder: URL, phase: @escaping @Sendable (LinkDownloadPhase) -> Void
    ) async throws -> URL {
        if !isToolInstalled {
            phase(.settingUp)
            try await installTool()
        }
        do {
            return try await runVideo(link, option: option, convert: convert, into: folder, phase: phase)
        } catch let error as LinkDownloadError {
            guard case .failed = error else { throw error }
            phase(.updating)
            guard (try? await update()) == true else { throw error }
            return try await runVideo(link, option: option, convert: convert, into: folder, phase: phase)
        }
    }

    private func runVideo(_ link: URL, option: String, convert: Bool, into folder: URL, phase: @escaping @Sendable (LinkDownloadPhase) -> Void) async throws -> URL {
        let staging = toolFolder.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        // "a,b" downloads both streams as separate files: joining them is
        // DEX's job (yt-dlp would need ffmpeg).
        let arguments = [
            "--no-playlist", "--no-warnings", "--newline", "--no-mtime", "--no-part",
            "-f", "\(option),140/bestaudio[ext=m4a]",
            "-P", staging.path,
            "-o", "%(format_id)s.%(ext)s",
            "--write-thumbnail",
            "--progress-template", "download:DEX %(progress._percent_str)s",
            "--print", "after_move:DEX-FILE %(filepath)s",
            "--print", "after_move:DEX-TITLE %(track,title)s",
            "--print", "after_move:DEX-ARTIST %(artist,creator,uploader)s",
            "--print", "after_move:DEX-NAME %(title).180B",
            link.absoluteString,
        ]
        var files: [String] = []
        var fields: [String: String] = [:]
        var lastError = ""
        var part = 0
        var lastFraction = 0.0
        let status = try await Self.execute(toolURL, arguments) { line in
            if let fraction = Self.progress(in: line) {
                // The video comes first and is most of the bytes.
                if fraction + 0.05 < lastFraction { part = 1 }
                lastFraction = fraction
                phase(.downloading(part == 0 ? fraction * 0.93 : 0.93 + fraction * 0.07))
            }
            if line.hasPrefix("DEX-FILE ") { files.append(String(line.dropFirst("DEX-FILE ".count))) }
            for key in ["TITLE", "ARTIST", "NAME"] where line.hasPrefix("DEX-\(key) ") {
                let value = String(line.dropFirst("DEX-\(key) ".count))
                if value != "NA" && !value.isEmpty { fields[key] = value }
            }
            if line.hasPrefix("ERROR:") { lastError = line }
        }
        try Task.checkCancellation()
        let urls = files.map(URL.init(fileURLWithPath:))
        guard status == 0, let video = urls.first(where: { $0.pathExtension == "mp4" }),
              let audio = urls.first(where: { $0.pathExtension == "m4a" })
        else { throw LinkDownloadError.failed(Self.explain(lastError)) }

        let tags = AudioTags(title: fields["TITLE"], artist: fields["ARTIST"], artwork: Self.thumbnail(in: staging))
        let name = (fields["NAME"] ?? "Video").replacingOccurrences(of: "/", with: "-")
        let joined = staging.appendingPathComponent("joined.mp4")
        if convert {
            phase(.converting(0))
            let track = try await AVURLAsset(url: video).loadTracks(withMediaType: .video).first
            let height = Int(try await track?.load(.naturalSize).height ?? 2160)
            let fps = Int((try await track?.load(.nominalFrameRate) ?? 60).rounded())
            try await VideoConverter.convert(video: video, audio: audio, tags: tags,
                                             kbps: VideoConverter.bitRate(height: height, fps: fps), to: joined) { phase(.converting($0)) }
        } else {
            phase(.finishing)
            try await VideoMuxer.join(video: video, audio: audio, tags: tags, to: joined)
        }
        let destination = SafeOutput.defaultDestination(for: folder.appendingPathComponent(name).appendingPathExtension("mp4"), pathExtension: "mp4")
        try FileManager.default.moveItem(at: joined, to: destination)
        return destination
    }

    /// "DEX  42.3%" → 0.423
    static func progress(in line: String) -> Double? {
        guard line.hasPrefix("DEX ") else { return nil }
        let number = line.dropFirst(8).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        return Double(number).map { min(max($0 / 100, 0), 1) }
    }

    /// yt-dlp's errors in plain words where we recognise them.
    static func explain(_ error: String) -> String {
        let lower = error.lowercased()
        if lower.contains("requested format is not available") {
            return "This video has no AAC audio stream that can be saved without re-encoding."
        }
        if lower.contains("private video") || lower.contains("sign in") {
            return "This video is private or needs a signed-in account."
        }
        if lower.contains("unavailable") { return "This video isn't available." }
        if lower.contains("unable to download") || lower.contains("urlopen error") || lower.contains("network") {
            return "The download failed. Check your internet connection."
        }
        let detail = error.replacingOccurrences(of: "ERROR: ", with: "")
        return detail.isEmpty ? "The download failed." : "The download failed: \(detail)"
    }

    // MARK: - The tool

    /// Fetches yt-dlp and its checksum list from the latest release and
    /// installs it only if the SHA-256 matches.
    public func installTool() async throws {
        try FileManager.default.createDirectory(at: toolFolder, withIntermediateDirectories: true)
        let sums: String
        let binary: Data
        do {
            let (sumsData, _) = try await URLSession.shared.data(from: Self.releaseBase.appendingPathComponent("SHA2-256SUMS"))
            sums = String(decoding: sumsData, as: UTF8.self)
            let (binaryURL, response) = try await URLSession.shared.download(from: Self.releaseBase.appendingPathComponent(Self.binaryName))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            binary = try Data(contentsOf: binaryURL)
            try? FileManager.default.removeItem(at: binaryURL)
        } catch {
            throw LinkDownloadError.toolUnavailable(error.localizedDescription)
        }
        guard let expected = Self.checksum(for: Self.binaryName, in: sums) else {
            throw LinkDownloadError.toolUnavailable("the release has no checksum for \(Self.binaryName)")
        }
        let actual = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw LinkDownloadError.checksumMismatch }
        let temporary = toolFolder.appendingPathComponent(Self.binaryName + ".new")
        try binary.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        _ = try? FileManager.default.removeItem(at: toolURL)
        try FileManager.default.moveItem(at: temporary, to: toolURL)
    }

    /// Files a sandboxed app writes are quarantined, and quarantined
    /// programs can't be launched. The binary was verified against its
    /// published checksum, so the flag is cleared on it (and only it).
    func clearQuarantine() throws {
        let result = removexattr(toolURL.path, "com.apple.quarantine", 0)
        guard result == 0 || errno == ENOATTR else {
            throw LinkDownloadError.toolUnavailable("macOS won't let DEX run yt-dlp (\(String(cString: strerror(errno))))")
        }
    }

    static func checksum(for name: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, parts[1] == name { return parts[0].lowercased() }
        }
        return nil
    }

    /// yt-dlp's own updater (it verifies the release signature itself).
    /// Returns whether it ran successfully.
    public func update() async throws -> Bool {
        try await Self.execute(toolURL, ["-U"]) { _ in } == 0
    }

    // MARK: - Process

    /// Runs the tool with an argument array (never a shell), streaming its
    /// output line by line. Cancelling the task terminates it.
    static func execute(_ tool: URL, _ arguments: [String], line: @escaping (String) -> Void) async throws -> Int32 {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let reader = LineReader(line)
        output.fileHandleForReading.readabilityHandler = { handle in reader.consume(handle.availableData) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { process in
                    output.fileHandleForReading.readabilityHandler = nil
                    reader.consume(output.fileHandleForReading.readDataToEndOfFile())
                    reader.flush()
                    continuation.resume(returning: process.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: LinkDownloadError.toolUnavailable(error.localizedDescription))
                }
            }
        } onCancel: {
            process.terminate()
        }
    }
}

/// Splits streamed output into lines, on whichever thread it arrives.
private final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let line: (String) -> Void

    init(_ line: @escaping (String) -> Void) { self.line = line }

    func consume(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let text = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !text.isEmpty { line(text) }
        }
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        if !buffer.isEmpty { line(String(decoding: buffer, as: UTF8.self)) }
        buffer = Data()
    }
}
