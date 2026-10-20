import AVFoundation
@testable import AudioEngine
import Foundation
import MediaModel

/// Generates deterministic test audio so no binary fixtures live in the
/// repository. Lossy fixtures are made with DEX's own encoders.
struct AudioFixtures {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dex-audio-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    enum Signal { case sine, music }

    /// PCM WAV (or AIFF by extension). Samples are quantised to the bit
    /// depth, so what's in the file is known exactly.
    func pcm(_ name: String = "source.wav", rate: Double = 48_000, channels: Int = 2, bits: Int = 24,
             float: Bool = false, seconds: Double = 3, signal: Signal = .music) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: float,
            AVLinearPCMIsBigEndianKey: url.pathExtension == "aiff", AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        let scale = float ? 1 : Float(1 << (min(bits, 24) - 1))
        for frame in 0..<Int(frames) {
            let t = Double(frame) / rate
            for channel in 0..<channels {
                var value: Double
                switch signal {
                case .sine:
                    value = 0.5 * sin(2 * .pi * 440 * t)
                case .music:
                    // Chords, a moving tone and noise: something codecs work at.
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let noise = Double(Int64(bitPattern: seed) >> 40) / Double(1 << 23)
                    value = 0.25 * sin(2 * .pi * 220 * t) + 0.15 * sin(2 * .pi * (330 + 200 * sin(t)) * t)
                        + 0.1 * sin(2 * .pi * 1_760 * t * Double(channel + 1)) + 0.08 * noise
                }
                let sample = Float(value)
                buffer.floatChannelData![channel][frame] = float ? sample : (sample * scale).rounded() / scale
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// Encodes a fixture with DEX's own exporter.
    func encoded(_ source: URL, to format: AudioFormat, kbps: Int? = nil, name: String) async throws -> URL {
        let info = try AudioEngine.inspect(url: source)
        let plan = try AudioPlanner.plan(info, AudioRequest(target: format, bitRate: kbps, segments: [SampleRange(0, info.frames)]))
        let url = directory.appendingPathComponent(name)
        try await AudioEngine.export(source, plan: plan, to: url)
        return url
    }

    /// A VBR MP3 straight from LAME (the exporter only writes CBR).
    func vbrMP3(_ source: URL, quality: Int32, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let reader = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let writer = try MP3Writer(url: url, sampleRate: reader.processingFormat.sampleRate,
                                   channels: Int(reader.processingFormat.channelCount), kbps: 128, vbrQuality: quality)
        let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 8_192)!
        while reader.framePosition < reader.length {
            try reader.read(into: buffer)
            try writer.write(buffer)
        }
        try writer.finish()
        return url
    }
}

/// Every sample of a file, interleaved, as Apple's decoder produces it.
func decode(_ url: URL) throws -> (samples: [Float], channels: Int, rate: Double) {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let channels = Int(buffer.format.channelCount)
    var samples = [Float](repeating: 0, count: Int(buffer.frameLength) * channels)
    for frame in 0..<Int(buffer.frameLength) {
        for channel in 0..<channels { samples[frame * channels + channel] = buffer.floatChannelData![channel][frame] }
    }
    return (samples, channels, file.processingFormat.sampleRate)
}

extension Array where Element == Float {
    /// Interleaved samples for the given frame ranges, joined.
    func frames(_ ranges: [SampleRange], channels: Int) -> [Float] {
        ranges.flatMap { self[Int($0.start) * channels..<Int($0.end) * channels] }
    }

    func maxDifference(_ other: [Float]) -> Float {
        zip(self, other).reduce(0) { Swift.max($0, abs($1.0 - $1.1)) }
    }
}
