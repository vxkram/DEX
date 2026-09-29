import Foundation

/// Audio formats DEX can write. Each one names a codec in its usual
/// container: ALAC and AAC are saved as `.m4a`.
public enum AudioFormat: String, Codable, Sendable, CaseIterable {
    case wav
    case aiff
    case flac
    case alac
    case aac
    case mp3

    public var displayName: String {
        switch self {
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .flac: "FLAC"
        case .alac: "ALAC"
        case .aac: "AAC"
        case .mp3: "MP3"
        }
    }

    public var fileExtension: String {
        switch self {
        case .alac, .aac: "m4a"
        default: rawValue
        }
    }

    public var typeIdentifier: String {
        switch self {
        case .wav: "com.microsoft.waveform-audio"
        case .aiff: "public.aiff-audio"
        case .flac: "org.xiph.flac"
        case .alac, .aac: "com.apple.m4a-audio"
        case .mp3: "public.mp3"
        }
    }

    public var isLossless: Bool {
        switch self {
        case .wav, .aiff, .flac, .alac: true
        case .aac, .mp3: false
        }
    }

    /// Highest integer bit depth the encoder keeps (measured on macOS 27:
    /// Apple's FLAC encoder stops at 24-bit, ALAC keeps 32).
    public var maxBitDepth: Int {
        self == .flac ? 24 : 32
    }

    /// WAV can hold 32-bit float samples, so decoded MP3/AAC and float
    /// sources are stored exactly, peaks above full scale included.
    public var storesFloat: Bool { self == .wav }

    /// Highest sample rate the encoder accepts; higher rates are resampled.
    public var maxSampleRate: Double? {
        switch self {
        case .aac, .mp3: 48_000
        default: nil
        }
    }

    public var maxChannels: Int? { self == .mp3 ? 2 : nil }

    /// Short description for the format picker.
    public var summary: String {
        switch self {
        case .wav: "Uncompressed"
        case .aiff: "Uncompressed"
        case .flac: "Lossless, smaller"
        case .alac: "Lossless, Apple"
        case .aac: "Small, Apple"
        case .mp3: "Small, plays anywhere"
        }
    }
}

/// How the audio in a file is coded, independent of its container.
public enum AudioCodec: String, Codable, Sendable {
    case pcm, flac, alac, aac, mp3, other

    public var isLossless: Bool { self == .pcm || self == .flac || self == .alac }
}

/// Facts about an audio file, read without decoding it.
public struct AudioInfo: Codable, Sendable, Equatable {
    public var fileName: String
    public var fileSize: Int64
    /// The file's type (e.g. `public.mp3`).
    public var typeIdentifier: String
    public var codec: AudioCodec
    /// Human name of the codec, including ones DEX can only read.
    public var codecName: String
    public var sampleRate: Double
    public var channels: Int
    /// Integer bits per sample for PCM, FLAC and ALAC; nil for lossy codecs.
    public var bitDepth: Int?
    public var isFloat: Bool
    /// Length in sample frames (per channel).
    public var frames: Int64
    /// Average bit rate in bits per second, when the file says.
    public var bitRate: Int?
    /// Title, artist, artwork and the like.
    public var hasTags: Bool
    /// Highest absolute sample value, when the file has been analysed.
    /// Decoded MP3/AAC can exceed 1.0 (full scale).
    public var peak: Float?

    public init(
        fileName: String, fileSize: Int64, typeIdentifier: String, codec: AudioCodec, codecName: String,
        sampleRate: Double, channels: Int, bitDepth: Int?, isFloat: Bool = false, frames: Int64,
        bitRate: Int? = nil, hasTags: Bool = false, peak: Float? = nil
    ) {
        self.fileName = fileName
        self.fileSize = fileSize
        self.typeIdentifier = typeIdentifier
        self.codec = codec
        self.codecName = codecName
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
        self.isFloat = isFloat
        self.frames = frames
        self.bitRate = bitRate
        self.hasTags = hasTags
        self.peak = peak
    }

    public var duration: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }

    /// The writable format this file already is, if any: the target that
    /// can keep its data untouched.
    public var format: AudioFormat? {
        switch codec {
        case .pcm:
            switch typeIdentifier {
            case AudioFormat.wav.typeIdentifier: .wav
            case AudioFormat.aiff.typeIdentifier, "public.aifc-audio": .aiff
            default: nil
            }
        case .flac: typeIdentifier == AudioFormat.flac.typeIdentifier ? .flac : nil
        case .alac: Self.mpeg4Types.contains(typeIdentifier) ? .alac : nil
        case .aac: Self.mpeg4Types.contains(typeIdentifier) ? .aac : nil
        case .mp3: typeIdentifier == AudioFormat.mp3.typeIdentifier ? .mp3 : nil
        case .other: nil
        }
    }

    /// Containers AVFoundation can trim without re-encoding.
    static let mpeg4Types: Set<String> = ["com.apple.m4a-audio", "public.mpeg-4-audio", "public.mpeg-4"]
}

/// A span of sample frames, `start` included, `end` excluded.
public struct SampleRange: Codable, Sendable, Hashable, Comparable {
    public var start: Int64
    public var end: Int64

    public init(_ start: Int64, _ end: Int64) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public var length: Int64 { end - start }
    public var isEmpty: Bool { end <= start }

    public func clamped(to bounds: SampleRange) -> SampleRange {
        SampleRange(min(max(start, bounds.start), bounds.end), min(max(end, bounds.start), bounds.end))
    }

    public func contains(_ frame: Int64) -> Bool { frame >= start && frame < end }

    public static func < (a: SampleRange, b: SampleRange) -> Bool {
        (a.start, a.end) < (b.start, b.end)
    }
}

/// What the user has done to the timeline, in source sample frames: the
/// part kept by Trim, the sections removed by Cut, and the Split points.
public struct AudioEdit: Codable, Sendable, Equatable {
    /// nil = the whole file.
    public var trim: SampleRange?
    public var removed: [SampleRange]
    public var splits: [Int64]

    public init(trim: SampleRange? = nil, removed: [SampleRange] = [], splits: [Int64] = []) {
        self.trim = trim
        self.removed = removed
        self.splits = splits
    }

    public var isIdentity: Bool { trim == nil && removed.isEmpty }

    /// Removed sections, merged and in order.
    public var removedRanges: [SampleRange] { Self.merged(removed) }

    public func kept(length: Int64) -> SampleRange {
        let whole = SampleRange(0, length)
        return trim?.clamped(to: whole) ?? whole
    }

    /// The ranges that make up the output, in order. Removed sections are
    /// merged first, so overlapping cuts behave like one.
    public func segments(length: Int64) -> [SampleRange] {
        let kept = kept(length: length)
        var segments: [SampleRange] = []
        var cursor = kept.start
        for cut in Self.merged(removed.map { $0.clamped(to: kept) }) where !cut.isEmpty {
            if cut.start > cursor { segments.append(SampleRange(cursor, cut.start)) }
            cursor = max(cursor, cut.end)
        }
        if kept.end > cursor { segments.append(SampleRange(cursor, kept.end)) }
        return segments
    }

    public func outputLength(length: Int64) -> Int64 {
        segments(length: length).reduce(0) { $0 + $1.length }
    }

    /// The output divided at the split points: one list of segments per
    /// part. Points outside the kept audio or inside removed sections are
    /// ignored, as are parts that would be empty.
    public func parts(length: Int64) -> [[SampleRange]] {
        let segments = segments(length: length)
        guard let first = segments.first, let last = segments.last else { return [] }
        let points = Set(splits.filter { point in
            point > first.start && segments.contains { $0.start <= point && point < $0.end }
        }).sorted()
        var bounds = [first.start] + points + [last.end]
        bounds = bounds.enumerated().filter { $0.offset == 0 || $0.element > bounds[$0.offset - 1] }.map(\.element)
        var parts: [[SampleRange]] = []
        for index in 0..<(bounds.count - 1) {
            let window = SampleRange(bounds[index], bounds[index + 1])
            let part = segments.map { $0.clamped(to: window) }.filter { !$0.isEmpty }
            if !part.isEmpty { parts.append(part) }
        }
        return parts
    }

    static func merged(_ ranges: [SampleRange]) -> [SampleRange] {
        var result: [SampleRange] = []
        for range in ranges.sorted() where !range.isEmpty {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1].end = max(last.end, range.end)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

/// Cover art, as encoded image bytes (JPEG or PNG).
public struct Artwork: Codable, Sendable, Hashable {
    public var data: Data
    public var isPNG: Bool

    public init(data: Data) {
        self.data = data
        isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }

    public var mimeType: String { isPNG ? "image/png" : "image/jpeg" }
}

/// The tags DEX reads and writes: what players show.
public struct AudioTags: Codable, Sendable, Hashable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var artwork: Artwork?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, artwork: Artwork? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
    }

    public var isEmpty: Bool {
        [title, artist, album].allSatisfy { ($0 ?? "").isEmpty } && artwork == nil
    }
}

extension AudioFormat {
    /// WAV and AIFF are written without tags (players rarely read them).
    public var storesTags: Bool { self != .wav && self != .aiff }
}

public struct AudioRequest: Codable, Sendable, Equatable {
    public var target: AudioFormat
    /// Bit rate for MP3 and AAC in kbit/s. nil = best: keep the source's
    /// data when it's already in this format, otherwise the highest rate.
    public var bitRate: Int?
    /// The source ranges to write, in order.
    public var segments: [SampleRange]
    /// Tags for the output. nil = keep what the route keeps (the source's
    /// own tags when data is copied, none otherwise).
    public var tags: AudioTags?

    public static let bitRates = [128, 192, 256, 320]
    public static let maximumBitRate = 320

    public init(target: AudioFormat, bitRate: Int? = nil, segments: [SampleRange], tags: AudioTags? = nil) {
        self.target = target
        self.bitRate = bitRate
        self.segments = segments
        self.tags = tags
    }
}

public enum AudioStrategy: String, Codable, Sendable {
    /// MP3 frames copied as they are, with a new gapless header so the cut
    /// lands on the exact sample.
    case copyFrames
    /// AVFoundation passthrough: AAC/ALAC packets copied into a new M4A.
    case passthrough
    /// Decoded and stored in a lossless format: every sample kept.
    case decodeLossless
    /// Encoded with a lossy codec.
    case encode
}

public enum AudioNote: Codable, Sendable, Equatable, CustomStringConvertible {
    // Losses
    case lossyEncode(AudioFormat, kbps: Int)
    case reencodedFrom(AudioCodec)
    case bitDepthReduced(from: Int, to: Int)
    case floatToInteger(bits: Int)
    case peaksClipped
    case resampled(from: Double, to: Double)
    case downmixed(from: Int, to: Int)
    case joinNeedsReencode(AudioFormat)
    // Information
    case samplesCopied
    case framesCopied
    case noAdditionalLoss(bits: Int?)
    case tagsNotCopied

    public var isLoss: Bool {
        switch self {
        case .samplesCopied, .framesCopied, .noAdditionalLoss, .tagsNotCopied: false
        default: true
        }
    }

    public var description: String {
        switch self {
        case .lossyEncode(let format, let kbps):
            "\(format.displayName) encoding at \(kbps) kbit/s"
        case .reencodedFrom(let codec):
            "The audio is already \(codec.displayName); compressing it again adds a second generation of loss"
        case .bitDepthReduced(let from, let to):
            "Bit depth reduced from \(from)-bit to \(to)-bit"
        case .floatToInteger(let bits):
            "32-bit float samples are stored as \(bits)-bit integers"
        case .peaksClipped:
            "Peaks above full scale will be clipped (WAV keeps them)"
        case .resampled(let from, let to):
            "Resampled from \(Self.kHz(from)) to \(Self.kHz(to)) kHz"
        case .downmixed(let from, let to):
            "\(from) channels mixed down to \(to == 2 ? "stereo" : "\(to)")"
        case .joinNeedsReencode(let format):
            "Removing a section from the middle of an \(format.displayName) means re-encoding it. Trim and Split keep the original data"
        case .samplesCopied:
            "Every sample is copied exactly"
        case .framesCopied:
            "The compressed audio is copied as it is, cut to the exact sample"
        case .noAdditionalLoss(let bits):
            "No additional loss" + (bits.map { ": decoded audio stored at \($0)-bit" } ?? "")
                + ". It can't restore what the original compression removed, and the file will be larger"
        case .tagsNotCopied:
            "WAV and AIFF are saved without the title, artist and artwork"
        }
    }

    static func kHz(_ rate: Double) -> String {
        let value = rate / 1000
        return value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }
}

extension AudioCodec {
    public var displayName: String {
        switch self {
        case .pcm: "PCM"
        case .flac: "FLAC"
        case .alac: "ALAC"
        case .aac: "AAC"
        case .mp3: "MP3"
        case .other: "compressed"
        }
    }
}

public struct AudioPlan: Codable, Sendable, Equatable {
    public var request: AudioRequest
    public var strategy: AudioStrategy
    public var verdict: QualityVerdict
    public var notes: [AudioNote]
    public var losslessAlternative: AudioFormat?
    public var sampleRate: Double
    public var sourceSampleRate: Double
    public var channels: Int
    /// Integer bits per sample of the output; nil for float or lossy.
    public var bitDepth: Int?
    public var isFloat: Bool
    /// Bit rate for lossy encodes, kbit/s.
    public var bitRate: Int?
    /// Output length in the source's sample frames.
    public var frames: Int64

    /// Output length at the output's sample rate.
    public var outputFrames: Int64 {
        sampleRate == sourceSampleRate ? frames : Int64((Double(frames) * sampleRate / sourceSampleRate).rounded())
    }
    /// Predicted file size when it can be worked out without encoding.
    public var predictedBytes: Int64?
}

public enum AudioPlanError: Error, Equatable, CustomStringConvertible {
    case nothingToExport
    case unreadable(String)

    public var description: String {
        switch self {
        case .nothingToExport: "Nothing is left to export: the whole file has been cut."
        case .unreadable(let name): "“\(name)” isn't an audio format DEX can read."
        }
    }
}

/// Decides how an audio export will be done and what it will cost.
///
/// Pure and deterministic, like the image `Planner`: the UI shows the
/// verdict live and tests cover every combination.
public enum AudioPlanner {
    public static func plan(_ source: AudioInfo, _ request: AudioRequest) throws -> AudioPlan {
        let segments = request.segments.filter { !$0.isEmpty }
        guard !segments.isEmpty else { throw AudioPlanError.nothingToExport }
        let target = request.target
        let frames = segments.reduce(0) { $0 + $1.length }
        let wholeFile = segments == [SampleRange(0, source.frames)]
        let sameFormat = source.format == target
        let keepsData = sameFormat && segments.count == 1 && (request.bitRate == nil || target.isLossless)

        var plan = AudioPlan(
            request: request, strategy: .decodeLossless, verdict: .lossless, notes: [], losslessAlternative: nil,
            sampleRate: source.sampleRate, sourceSampleRate: source.sampleRate, channels: source.channels, bitDepth: nil, isFloat: false, bitRate: nil,
            frames: frames, predictedBytes: nil
        )
        var losses: [AudioNote] = []
        var info: [AudioNote] = []

        if keepsData && (target == .mp3 || target == .aac || target == .alac) {
            plan.strategy = target == .mp3 ? .copyFrames : .passthrough
            plan.verdict = .noReencode
            plan.bitDepth = source.bitDepth
            plan.bitRate = source.bitRate.map { $0 / 1000 }
            plan.predictedBytes = wholeFile ? source.fileSize
                : Int64(Double(source.fileSize) * Double(frames) / Double(max(source.frames, 1)))
            info.append(target == .alac ? .samplesCopied : .framesCopied)
        } else if target.isLossless {
            plan.strategy = .decodeLossless
            let depth = source.bitDepth ?? 32
            if source.codec.isLossless && !source.isFloat {
                plan.bitDepth = min(depth, target.maxBitDepth)
                if depth > target.maxBitDepth { losses.append(.bitDepthReduced(from: depth, to: target.maxBitDepth)) }
                else { info.append(.samplesCopied) }
            } else if target.storesFloat {
                // Float sources and decoded MP3/AAC: 32-bit float is exact.
                plan.isFloat = true
                if source.isFloat && depth > 32 { losses.append(.bitDepthReduced(from: depth, to: 32)) }
                else { info.append(source.codec.isLossless ? .samplesCopied : .noAdditionalLoss(bits: nil)) }
            } else {
                let bits = min(24, target.maxBitDepth)
                plan.bitDepth = bits
                if source.codec.isLossless { losses.append(.floatToInteger(bits: bits)) }
                else { info.append(.noAdditionalLoss(bits: bits)) }
                if (source.peak ?? 0) > 1 { losses.append(.peaksClipped) }
            }
            if sameFormat && (target == .wav || target == .aiff) && losses.isEmpty && plan.bitDepth == source.bitDepth {
                plan.verdict = .noReencode
            }
            let bytesPerSample = plan.isFloat ? 4 : ((plan.bitDepth ?? 24) + 7) / 8
            if target == .wav || target == .aiff {
                plan.predictedBytes = frames * Int64(source.channels * bytesPerSample) + 44
            }
        } else {
            plan.strategy = .encode
            let kbps = request.bitRate ?? AudioRequest.maximumBitRate
            plan.bitRate = kbps
            losses.append(.lossyEncode(target, kbps: kbps))
            if !source.codec.isLossless {
                if sameFormat && segments.count > 1 && request.bitRate == nil {
                    losses.append(.joinNeedsReencode(target))
                } else {
                    losses.append(.reencodedFrom(source.codec))
                }
            }
            if let maxRate = target.maxSampleRate, source.sampleRate > maxRate {
                let rate = source.sampleRate.truncatingRemainder(dividingBy: 44_100) == 0 ? 44_100 : maxRate
                plan.sampleRate = rate
                losses.append(.resampled(from: source.sampleRate, to: rate))
            }
            if let maxChannels = target.maxChannels, source.channels > maxChannels {
                plan.channels = maxChannels
                losses.append(.downmixed(from: source.channels, to: maxChannels))
            }
            plan.predictedBytes = Int64(Double(frames) / source.sampleRate * Double(kbps) * 125)
        }

        let hasTags = request.tags.map { !$0.isEmpty } ?? source.hasTags
        if hasTags && !target.storesTags {
            info.append(.tagsNotCopied)
        } else if request.tags == nil && source.hasTags && plan.strategy != .copyFrames && plan.strategy != .passthrough {
            info.append(.tagsNotCopied)
        }
        plan.notes = losses + info
        if !losses.isEmpty {
            plan.verdict = .lossy
            plan.losslessAlternative = [AudioFormat.flac, .wav].first { candidate in
                guard candidate != target else { return false }
                var alternative = request
                alternative.target = candidate
                return (try? Self.plan(source, alternative)).map { $0.verdict != .lossy } ?? false
            }
        }
        return plan
    }
}
