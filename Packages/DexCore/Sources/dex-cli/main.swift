import Foundation
import ImageEngine
import MediaModel

let usage = """
    usage: dex <command> [options]

    commands:
      inspect <file>... [--json]   Show format, geometry, colour and metadata facts
      formats [--json]             List image formats this Mac can read and write
      help                         Show this message
    """

enum ExitCode: Int32 {
    case ok = 0
    case failure = 1
    case usage = 64
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func jsonString<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

func describe(_ info: MediaInfo) -> String {
    var lines = [
        info.fileName,
        "  format       \(info.format?.rawValue ?? "unsupported") (\(info.typeIdentifier))",
        "  size         \(ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file))",
        "  dimensions   \(info.displayWidth) × \(info.displayHeight)",
    ]
    if info.orientation != 1 {
        lines.append("  orientation  \(info.orientation) (stored \(info.pixelWidth) × \(info.pixelHeight))")
    }
    let depth = info.bitsPerComponent.map { "\($0)-bit" } ?? "unknown depth"
    lines.append("  colour       \(info.colorModel ?? "unknown") \(depth), \(info.colorProfile ?? "no profile")")
    lines.append("  alpha        \(info.hasAlpha ? "yes" : "no")")
    lines.append("  HDR          \(info.hasHDRGainMap ? "gain map" : "no")")
    if info.isAnimated { lines.append("  frames       \(info.frameCount)") }
    lines.append("  location     \(info.hasGPS ? "GPS present" : "none")")
    return lines.joined(separator: "\n")
}

func inspect(_ arguments: [String]) -> ExitCode {
    let asJSON = arguments.contains("--json")
    let paths = arguments.filter { $0 != "--json" }
    guard !paths.isEmpty else {
        printError("dex inspect: no files given\n\n\(usage)")
        return .usage
    }

    var results: [MediaInfo] = []
    var failed = false
    for path in paths {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            let info = try ImageEngine.inspect(url: url)
            results.append(info)
            if !asJSON { print(describe(info)) }
        } catch {
            failed = true
            printError("dex: \(error)")
        }
    }
    if asJSON {
        do {
            print(try jsonString(results))
        } catch {
            printError("dex: could not encode JSON: \(error)")
            return .failure
        }
    }
    return failed ? .failure : .ok
}

struct FormatSupport: Encodable {
    var format: String
    var typeIdentifier: String
    var read: Bool
    var write: Bool
}

func formats(_ arguments: [String]) -> ExitCode {
    let readable = Set(ImageEngine.readableTypeIdentifiers())
    let writable = Set(ImageEngine.writableTypeIdentifiers())
    let rows = ImageFormat.allCases.map {
        FormatSupport(
            format: $0.rawValue,
            typeIdentifier: $0.typeIdentifier,
            read: readable.contains($0.typeIdentifier),
            write: writable.contains($0.typeIdentifier)
        )
    }
    if arguments.contains("--json") {
        do {
            print(try jsonString(rows))
        } catch {
            printError("dex: could not encode JSON: \(error)")
            return .failure
        }
        return .ok
    }
    print("format  read   write  (native ImageIO on macOS \(ProcessInfo.processInfo.operatingSystemVersionString))")
    for row in rows {
        let name = row.format.padding(toLength: 8, withPad: " ", startingAt: 0)
        print("\(name)\(row.read ? "yes" : "no ")    \(row.write ? "yes" : "no")")
    }
    return .ok
}

let arguments = Array(CommandLine.arguments.dropFirst())
let code: ExitCode
switch arguments.first {
case "inspect": code = inspect(Array(arguments.dropFirst()))
case "formats": code = formats(Array(arguments.dropFirst()))
case "help", "--help", "-h": print(usage); code = .ok
case nil: printError(usage); code = .usage
case let other?: printError("dex: unknown command '\(other)'\n\n\(usage)"); code = .usage
}
exit(code.rawValue)
