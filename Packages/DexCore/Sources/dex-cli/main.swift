import Foundation
import ImageEngine
import JobSystem
import MediaModel

let usage = """
    usage: dex <command> [options]

    commands:
      inspect <file>... [--json]   Show format, geometry, colour and metadata facts
      convert <file> --to <format> [options]
                                   Convert, choosing the most lossless path available
      formats [--json]             List image formats this Mac can read and write
      help                         Show this message

    convert options:
      --to <format>                jpeg, png, heic, avif, tiff, gif
      --out <path>                 Output file (default: next to the original, never overwriting it)
      --quality max|<0-1>          Lossy encoder quality (default: max = 0.95)
      --metadata <policy>          keep | no-location (default) | none
      --allow-lossy                Accept a conversion that loses information
      --overwrite                  Replace an existing output file (never the original)
      --dry-run                    Show the plan without writing anything
    """

enum ExitCode: Int32 {
    case ok = 0
    case failure = 1
    /// A lossy conversion was planned but not accepted with --allow-lossy.
    case needsConsent = 2
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

func describe(_ plan: ConversionPlan) -> String {
    var lines = ["  verdict      \(plan.verdict.label)"]
    for note in plan.notes {
        lines.append("  \(note.isLoss ? "-" : "·") \(note)")
    }
    if let alternative = plan.losslessAlternative {
        lines.append("  lossless alternative: --to \(alternative.rawValue)")
    }
    return lines.joined(separator: "\n")
}

struct ConvertOptions {
    var input: String?
    var target: ImageFormat?
    var output: String?
    var quality = QualityPreference.maximum
    var metadata = MetadataPolicy.removeLocation
    var allowLossy = false
    var overwrite = false
    var dryRun = false
}

func parseConvertOptions(_ arguments: [String]) throws -> ConvertOptions {
    struct UsageError: Error, CustomStringConvertible { var description: String }
    var options = ConvertOptions()
    var remaining = arguments[...]
    func value(for flag: String) throws -> String {
        guard let next = remaining.popFirst() else { throw UsageError(description: "\(flag) needs a value") }
        return next
    }
    while let argument = remaining.popFirst() {
        switch argument {
        case "--to":
            let name = try value(for: argument).lowercased()
            let aliases = ["jpg": "jpeg", "tif": "tiff"]
            guard let format = ImageFormat(rawValue: aliases[name] ?? name) else {
                throw UsageError(description: "unknown format '\(name)'")
            }
            options.target = format
        case "--out":
            options.output = try value(for: argument)
        case "--quality":
            let raw = try value(for: argument)
            if raw == "max" {
                options.quality = .maximum
            } else if let number = Double(raw), (0...1).contains(number) {
                options.quality = .custom(number)
            } else {
                throw UsageError(description: "--quality must be 'max' or a number from 0 to 1")
            }
        case "--metadata":
            switch try value(for: argument) {
            case "keep": options.metadata = .keepAll
            case "no-location": options.metadata = .removeLocation
            case "none": options.metadata = .removeAll
            case let other: throw UsageError(description: "unknown metadata policy '\(other)'")
            }
        case "--allow-lossy": options.allowLossy = true
        case "--overwrite": options.overwrite = true
        case "--dry-run": options.dryRun = true
        case let flag where flag.hasPrefix("--"):
            throw UsageError(description: "unknown option \(flag)")
        default:
            guard options.input == nil else { throw UsageError(description: "convert takes one input file") }
            options.input = argument
        }
    }
    guard options.input != nil else { throw UsageError(description: "no input file given") }
    guard options.target != nil else { throw UsageError(description: "--to <format> is required") }
    return options
}

func convert(_ arguments: [String]) async -> ExitCode {
    let options: ConvertOptions
    do {
        options = try parseConvertOptions(arguments)
    } catch {
        printError("dex convert: \(error)\n\n\(usage)")
        return .usage
    }
    let source = URL(fileURLWithPath: (options.input! as NSString).expandingTildeInPath)
    let request = ConvertRequest(target: options.target!, quality: options.quality, metadata: options.metadata)

    do {
        let (_, plan) = try ImageEngine.plan(source, request)
        let destination = options.output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? SafeOutput.defaultDestination(for: source, pathExtension: request.target.preferredFileExtension)
        print("\(source.lastPathComponent) → \(destination.lastPathComponent)")
        print(describe(plan))

        if options.dryRun { return .ok }
        if SafeOutput.isSameFile(destination, source) {
            throw OutputError.wouldOverwriteSource(source.lastPathComponent)
        }
        if plan.verdict == .lossy && !options.allowLossy {
            printError("\nThis conversion loses information. Re-run with --allow-lossy to accept it"
                + (plan.losslessAlternative.map { ", or use --to \($0.rawValue) to avoid it." } ?? "."))
            return .needsConsent
        }
        try await ImageEngine.convert(source, plan: plan, to: destination, overwrite: options.overwrite)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        print("  saved        \(destination.path) (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))")
        return .ok
    } catch {
        printError("dex: \(error)")
        return .failure
    }
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

// Keep stdout and stderr in order when piped.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
let code: ExitCode
switch arguments.first {
case "inspect": code = inspect(Array(arguments.dropFirst()))
case "convert": code = await convert(Array(arguments.dropFirst()))
case "formats": code = formats(Array(arguments.dropFirst()))
case "help", "--help", "-h": print(usage); code = .ok
case nil: printError(usage); code = .usage
case let other?: printError("dex: unknown command '\(other)'\n\n\(usage)"); code = .usage
}
exit(code.rawValue)
