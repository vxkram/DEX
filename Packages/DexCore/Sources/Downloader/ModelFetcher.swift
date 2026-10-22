import Foundation

/// Streams one of DEX's Enhance models into a file the app opened, so the
/// sandboxed app never touches the network and the service never touches
/// the app's container. The app checks the result against its pinned
/// SHA-256 before using it.
public enum ModelFetcher {
    /// Only DEX's own model releases.
    public static let allowedPrefix = "https://github.com/vxkram/DEX/releases/download/models-"

    public enum FetchError: Error, CustomStringConvertible {
        case notAModelURL
        case failed(String)

        public var description: String {
            switch self {
            case .notAModelURL: "That isn't one of DEX's model downloads."
            case .failed(let reason): "The model download failed: \(reason)"
            }
        }
    }

    public static func fetch(_ link: String, into file: FileHandle, progress: @Sendable (Double) -> Void) async throws {
        guard link.hasPrefix(allowedPrefix), link.hasSuffix(".mlpackage.zip"), let url = URL(string: link) else {
            throw FetchError.notAModelURL
        }
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw FetchError.failed("the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let expected = max(response.expectedContentLength, 1)
        var chunk = Data()
        chunk.reserveCapacity(1 << 20)
        var written: Int64 = 0
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == 1 << 20 {
                try Task.checkCancellation()
                try file.write(contentsOf: chunk)
                written += Int64(chunk.count)
                chunk.removeAll(keepingCapacity: true)
                progress(Double(written) / Double(expected))
            }
        }
        try file.write(contentsOf: chunk)
        try file.synchronize()
        progress(1)
    }
}
