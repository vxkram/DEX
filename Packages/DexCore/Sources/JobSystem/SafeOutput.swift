import Foundation

public enum OutputError: Error, Equatable, CustomStringConvertible {
    case wouldOverwriteSource(String)
    case destinationExists(String)
    case folderMissing(String)

    public var description: String {
        switch self {
        case .wouldOverwriteSource(let name): "Refusing to overwrite the original file “\(name)”."
        case .destinationExists(let name): "“\(name)” already exists. Choose another name or allow overwriting."
        case .folderMissing(let path): "The output folder “\(path)” doesn't exist."
        }
    }
}

/// Writes outputs so that a crash, error or cancellation never leaves a
/// half-written file, and the source is never modified.
public enum SafeOutput {
    /// `photo.heic` → `photo.jpg` next to the source, or `photo 2.jpg`,
    /// `photo 3.jpg`, … if that name is taken (including by the source itself).
    public static func defaultDestination(for source: URL, pathExtension: String) -> URL {
        let folder = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(pathExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(counter)").appendingPathExtension(pathExtension)
            counter += 1
        }
        return candidate
    }

    /// Runs `produce` against a temporary file on the destination's volume,
    /// then moves the result into place atomically. The temporary file is
    /// removed on every path, including errors and cancellation.
    public static func write(
        to destination: URL,
        source: URL,
        overwrite: Bool = false,
        cancellation: CancellationToken? = nil,
        _ produce: (URL) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let folder = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OutputError.folderMissing(folder.path)
        }
        if isSameFile(destination, source) {
            throw OutputError.wouldOverwriteSource(source.lastPathComponent)
        }
        let exists = fileManager.fileExists(atPath: destination.path)
        if exists && !overwrite {
            throw OutputError.destinationExists(destination.lastPathComponent)
        }

        let scratch = try fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true
        )
        defer { try? fileManager.removeItem(at: scratch) }
        let temporary = scratch.appendingPathComponent(destination.lastPathComponent)

        try produce(temporary)
        try cancellation?.check()

        if exists {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    /// Compares file identity rather than path strings, so symlinks, case
    /// differences and `..` segments can't trick us into overwriting the source.
    public static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        // Resource values describe a symlink itself, so resolve links first.
        let a = a.standardizedFileURL.resolvingSymlinksInPath()
        let b = b.standardizedFileURL.resolvingSymlinksInPath()
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        if let idA = try? a.resourceValues(forKeys: key).fileResourceIdentifier,
           let idB = try? b.resourceValues(forKeys: key).fileResourceIdentifier {
            return idA.isEqual(idB)
        }
        return a == b
    }
}
