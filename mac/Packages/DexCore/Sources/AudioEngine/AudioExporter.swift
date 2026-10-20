import AudioTagging
import AudioToolbox
import AVFoundation
import Foundation
import JobSystem
import MediaModel

public enum AudioExportError: Error, Equatable, CustomStringConvertible {
    case encoderFailed(String)
    case verificationFailed(String)
    case passthroughFailed(String)

    public var description: String {
        switch self {
        case .encoderFailed(let detail): "Encoding failed: \(detail)."
        case .verificationFailed(let detail): "The saved file didn't check out (\(detail)), so it was not kept."
        case .passthroughFailed(let detail): "Copying the audio failed: \(detail)."
        }
    }
}

extension AudioEngine {
    /// Writes the plan's segments to `destination` by the most lossless
    /// route the plan chose, then reopens the result to check its length
    /// and format before moving it into place. The source is never touched.
    public static func export(
        _ source: URL,
        plan: AudioPlan,
        to destination: URL,
        overwrite: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let target = plan.request.target
        let tags = target.storesTags ? plan.request.tags : nil
        // Copy routes already keep the source's tags; only rewrite them if
        // they changed (e.g. new artwork).
        let copies = plan.strategy == .copyFrames || plan.strategy == .passthrough
        let retag: AudioTags? = if let tags, copies { await AudioTagging.tags(of: source) == tags ? nil : tags } else { tags }
        try await SafeOutput.write(to: destination, source: source, overwrite: overwrite) { temporary in
            switch plan.strategy {
            case .passthrough:
                let range = plan.request.segments[0]
                let scale = CMTimeScale(plan.sampleRate)
                do {
                    try await AudioTagging.passthrough(
                        source,
                        range: CMTimeRange(start: CMTime(value: range.start, timescale: scale), end: CMTime(value: range.end, timescale: scale)),
                        metadata: retag.map(AudioTagging.metadataItems), to: temporary
                    )
                } catch {
                    throw AudioExportError.passthroughFailed(String(describing: error))
                }
            default:
                try await MediaWork.run { token in
                    if plan.strategy == .copyFrames {
                        let stream = try MP3Stream(data: Data(contentsOf: source, options: .alwaysMapped))
                        let range = plan.request.segments[0]
                        try stream.cut(range.start..<range.end).write(to: temporary)
                    } else {
                        try transcode(source, plan: plan, to: temporary, token: token, progress: progress)
                    }
                }
                if let retag { try await AudioTagging.write(retag, to: temporary, format: target) }
            }
            try verify(temporary, plan: plan)
        }
        progress?(1)
    }

    /// Measures the output size by encoding up to 20 seconds of the first
    /// segment and scaling, for codecs whose size can't be predicted.
    public static func estimatedSize(_ source: URL, plan: AudioPlan) async throws -> Int64 {
        if let predicted = plan.predictedBytes { return predicted }
        let sampleFrames = Int64(20 * plan.sampleRate)
        guard let first = plan.request.segments.first else { return 0 }
        let middle = first.start + max(0, (first.length - sampleFrames) / 2)
        var sample = plan
        sample.request.segments = [SampleRange(middle, min(middle + sampleFrames, first.end))]
        sample.frames = sample.request.segments[0].length
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dex-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("estimate.\(plan.request.target.fileExtension)")
        let excerpt = sample
        try await MediaWork.run { token in try transcode(source, plan: excerpt, to: output, token: token, progress: nil) }
        let bytes = Int64(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        return Int64(Double(bytes) * Double(plan.frames) / Double(max(sample.frames, 1)))
    }

    // MARK: - Decode and encode

    private static func transcode(
        _ source: URL, plan: AudioPlan, to output: URL, token: CancellationToken, progress: (@Sendable (Double) -> Void)?
    ) throws {
        let target = plan.request.target
        let info = try inspect(url: source)
        // Int32 keeps 32-bit integer sources exact; float32 is exact for
        // everything up to 24-bit and for float and decoded lossy audio.
        let common: AVAudioCommonFormat = target.isLossless && !plan.isFloat && (plan.bitDepth ?? 0) > 24
            && info.codec.isLossless && !info.isFloat ? .pcmFormatInt32 : .pcmFormatFloat32
        let reader = try AVAudioFile(forReading: source, commonFormat: common, interleaved: false)

        // The buffers handed to the writer: the reader's sample type at the
        // output's rate and channel count.
        let outputFormat: AVAudioFormat
        if let layout = reader.processingFormat.channelLayout, plan.channels == Int(reader.processingFormat.channelCount) {
            outputFormat = AVAudioFormat(commonFormat: common, sampleRate: plan.sampleRate, interleaved: false, channelLayout: layout)
        } else {
            outputFormat = AVAudioFormat(commonFormat: common, sampleRate: plan.sampleRate,
                                         channels: AVAudioChannelCount(plan.channels), interleaved: false)!
        }
        let sink: PCMSink = target == .mp3
            ? .mp3(try MP3Writer(url: output, sampleRate: plan.sampleRate, channels: plan.channels, kbps: plan.bitRate ?? AudioRequest.maximumBitRate))
            : .file(try ExtAudioWriter(url: output, plan: plan, client: outputFormat))

        var source = SegmentReader(file: reader, segments: plan.request.segments, token: token, progress: progress)
        let needsConversion = outputFormat.sampleRate != reader.processingFormat.sampleRate
            || outputFormat.channelCount != reader.processingFormat.channelCount
        if !needsConversion {
            while let buffer = try source.next() { try sink.write(buffer) }
        } else {
            guard let converter = AVAudioConverter(from: reader.processingFormat, to: outputFormat) else {
                throw AudioExportError.encoderFailed("can't convert \(reader.processingFormat) to \(outputFormat)")
            }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter.downmix = true
            let capacity = AVAudioFrameCount(Double(SegmentReader.chunk) * outputFormat.sampleRate / reader.processingFormat.sampleRate) + 1024
            var failure: Error?
            var finished = false
            while !finished {
                guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { break }
                var error: NSError?
                let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                    do {
                        if let buffer = try source.next() {
                            inputStatus.pointee = .haveData
                            return buffer
                        }
                    } catch {
                        failure = error
                    }
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if let failure { throw failure }
                if let error { throw AudioExportError.encoderFailed(error.localizedDescription) }
                if converted.frameLength > 0 { try sink.write(converted) }
                finished = status == .endOfStream || status == .error
            }
        }
        try sink.finish()
    }

    // MARK: - Verification

    /// Reopens the written file: it must decode to the planned length,
    /// rate and channel count (resampling may round by a frame or two).
    private static func verify(_ url: URL, plan: AudioPlan) throws {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw AudioExportError.verificationFailed("it can't be read back")
        }
        let format = file.fileFormat
        let resampled = plan.sampleRate != plan.sourceSampleRate
        let expected = resampled ? Int64((Double(plan.frames) * plan.sampleRate / plan.sourceSampleRate).rounded()) : plan.frames
        guard abs(file.length - expected) <= (resampled ? 2 : 0) else {
            throw AudioExportError.verificationFailed("\(file.length) samples instead of \(expected)")
        }
        guard format.sampleRate == plan.sampleRate, Int(format.channelCount) == plan.channels else {
            throw AudioExportError.verificationFailed("\(Int(format.sampleRate)) Hz, \(format.channelCount) channels")
        }
    }
}

/// Reads the planned segments from the source in order, in chunks.
private struct SegmentReader {
    static let chunk: AVAudioFrameCount = 32_768

    let file: AVAudioFile
    let segments: [SampleRange]
    let token: CancellationToken
    let progress: (@Sendable (Double) -> Void)?
    private var index = 0
    private var position: Int64?
    private var done: Int64 = 0
    private let total: Int64

    init(file: AVAudioFile, segments: [SampleRange], token: CancellationToken, progress: (@Sendable (Double) -> Void)?) {
        self.file = file
        self.segments = segments
        self.token = token
        self.progress = progress
        total = max(segments.reduce(0) { $0 + $1.length }, 1)
    }

    mutating func next() throws -> AVAudioPCMBuffer? {
        try token.check()
        while index < segments.count {
            let segment = segments[index]
            let start = position ?? segment.start
            if position == nil { file.framePosition = start }
            let remaining = segment.end - start
            guard remaining > 0 else {
                index += 1
                position = nil
                continue
            }
            let count = AVAudioFrameCount(min(Int64(Self.chunk), remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return nil }
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else {
                index += 1
                position = nil
                continue
            }
            position = start + Int64(buffer.frameLength)
            done += Int64(buffer.frameLength)
            progress?(Double(done) / Double(total) * 0.98)
            return buffer
        }
        return nil
    }
}

private enum PCMSink {
    case file(ExtAudioWriter)
    case mp3(MP3Writer)

    func write(_ buffer: AVAudioPCMBuffer) throws {
        switch self {
        case .file(let writer): try writer.write(buffer)
        case .mp3(let writer): try writer.write(buffer)
        }
    }

    func finish() throws {
        switch self {
        case .file(let writer): try writer.finish()
        case .mp3(let writer): try writer.finish()
        }
    }
}
