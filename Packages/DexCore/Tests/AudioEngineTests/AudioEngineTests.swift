import AudioEngine
import AVFoundation
import Foundation
import JobSystem
import MediaModel
import Testing

@Suite("Audio engine", .serialized)
struct AudioEngineTests {
    let fixtures: AudioFixtures

    init() throws { fixtures = try AudioFixtures() }

    func export(_ source: URL, _ target: AudioFormat, segments: [SampleRange]? = nil, kbps: Int? = nil,
                name: String? = nil) async throws -> (URL, AudioPlan) {
        let info = try AudioEngine.inspect(url: source)
        let plan = try AudioPlanner.plan(info, AudioRequest(target: target, bitRate: kbps, segments: segments ?? [SampleRange(0, info.frames)]))
        let output = fixtures.directory.appendingPathComponent(name ?? "out-\(UUID().uuidString).\(target.fileExtension)")
        try await AudioEngine.export(source, plan: plan, to: output)
        return (output, plan)
    }

    // MARK: Inspect

    @Test("Inspect reads format facts without decoding")
    func inspect() throws {
        defer { fixtures.cleanUp() }
        let info = try AudioEngine.inspect(url: try fixtures.pcm(rate: 96_000, bits: 24, seconds: 1))
        #expect(info.codec == .pcm)
        #expect(info.format == .wav)
        #expect(info.sampleRate == 96_000)
        #expect(info.channels == 2)
        #expect(info.bitDepth == 24)
        #expect(info.frames == 96_000)
    }

    @Test("Waveform covers every frame and finds the peak")
    func waveform() async throws {
        defer { fixtures.cleanUp() }
        let url = try fixtures.pcm(seconds: 2, signal: .sine)
        let waveform = try await AudioEngine.waveform(url: url)
        #expect(waveform.frames == 96_000)
        #expect(waveform.mins.count * waveform.framesPerBucket >= 96_000)
        #expect(abs(waveform.peak - 0.5) < 0.001)
        // A sine's RMS is its peak / √2.
        #expect(abs(waveform.level(buckets: 0..<waveform.rms.count) - Float(0.5 / 2.0.squareRoot())) < 0.002)
    }

    // MARK: Lossless routes

    @Test("Trim and cut into lossless formats keep every sample", arguments: [AudioFormat.wav, .aiff, .flac, .alac])
    func losslessExact(_ target: AudioFormat) async throws {
        defer { fixtures.cleanUp() }
        let source = try fixtures.pcm(bits: 24)
        let segments = [SampleRange(1_234, 40_000), SampleRange(70_001, 140_000)]
        let (output, plan) = try await export(source, target, segments: segments)
        #expect(plan.verdict != .lossy)
        let original = try decode(source)
        let result = try decode(output)
        #expect(result.samples.count == original.samples.frames(segments, channels: 2).count)
        #expect(result.samples == original.samples.frames(segments, channels: 2))
        #expect(try AudioEngine.inspect(url: output).bitDepth == 24)
    }

    @Test("16-bit stays 16-bit in FLAC")
    func sixteenBit() async throws {
        defer { fixtures.cleanUp() }
        let source = try fixtures.pcm(rate: 44_100, bits: 16)
        let (output, _) = try await export(source, .flac)
        #expect(try AudioEngine.inspect(url: output).bitDepth == 16)
        #expect(try decode(output).samples == decode(source).samples)
    }

    @Test("32-bit integer audio into ALAC is exact")
    func thirtyTwoBit() async throws {
        defer { fixtures.cleanUp() }
        let source = try fixtures.pcm(bits: 32, seconds: 1)
        let (output, plan) = try await export(source, .alac)
        #expect(plan.bitDepth == 32)
        #expect(try AudioEngine.inspect(url: output).bitDepth == 32)
        let a = try AVAudioFile(forReading: source, commonFormat: .pcmFormatInt32, interleaved: false)
        let b = try AVAudioFile(forReading: output, commonFormat: .pcmFormatInt32, interleaved: false)
        let bufferA = AVAudioPCMBuffer(pcmFormat: a.processingFormat, frameCapacity: AVAudioFrameCount(a.length))!
        let bufferB = AVAudioPCMBuffer(pcmFormat: b.processingFormat, frameCapacity: AVAudioFrameCount(b.length))!
        try a.read(into: bufferA)
        try b.read(into: bufferB)
        #expect(bufferA.frameLength == bufferB.frameLength)
        #expect(memcmp(bufferA.int32ChannelData![0], bufferB.int32ChannelData![0], Int(bufferA.frameLength) * 4) == 0)
    }

    // MARK: MP3 frame copy

    @Test("Trimming an MP3 copies frames and decodes to exactly the source's samples",
          arguments: [(128, Int32?.none), (320, nil), (0, Int32(2)), (0, Int32(9))])
    func mp3FrameCopy(_ kbps: Int, _ vbr: Int32?) async throws {
        defer { fixtures.cleanUp() }
        let wav = try fixtures.pcm(rate: 44_100, bits: 16, seconds: 4)
        let mp3 = if let vbr { try fixtures.vbrMP3(wav, quality: vbr, name: "vbr.mp3") }
            else { try await fixtures.encoded(wav, to: .mp3, kbps: kbps, name: "cbr.mp3") }
        let original = try decode(mp3)
        let length = Int64(original.samples.count / 2)
        for range in [SampleRange(0, 10_000), SampleRange(1, length), SampleRange(44_100, 120_000),
                      SampleRange(3_000, 3_500), SampleRange(100_001, length)] {
            let (output, plan) = try await export(mp3, .mp3, segments: [range])
            #expect(plan.strategy == .copyFrames)
            let result = try decode(output)
            let expected = original.samples.frames([range], channels: 2)
            #expect(result.samples.count == expected.count, "\(range)")
            #expect(result.samples == expected, "\(range)")
        }
    }

    @Test("A copied MP3 keeps its ID3 tags")
    func mp3Tags() async throws {
        defer { fixtures.cleanUp() }
        let wav = try fixtures.pcm(rate: 44_100, bits: 16, seconds: 2)
        let mp3 = try await fixtures.encoded(wav, to: .mp3, name: "plain.mp3")
        // A minimal ID3v2.3 tag with a title frame.
        let title = Data([0]) + Data("Forge".utf8)
        var frame = Data("TIT2".utf8) + Data([0, 0, 0, UInt8(title.count), 0, 0]) + title
        let size = frame.count
        frame = Data("ID3".utf8) + Data([3, 0, 0, 0, 0, 0, UInt8(size)]) + frame
        let tagged = fixtures.directory.appendingPathComponent("tagged.mp3")
        try (frame + Data(contentsOf: mp3)).write(to: tagged)
        #expect(try AudioEngine.inspect(url: tagged).hasTags)
        let (output, _) = try await export(tagged, .mp3, segments: [SampleRange(5_000, 50_000)])
        #expect(try Data(contentsOf: output).prefix(frame.count) == frame)
        #expect(try decode(output).samples.count == 45_000 * 2)
    }

    // MARK: M4A passthrough

    @Test("Trimming AAC and ALAC in M4A is a passthrough and sample-exact", arguments: [AudioFormat.aac, .alac])
    func m4aPassthrough(_ format: AudioFormat) async throws {
        defer { fixtures.cleanUp() }
        let wav = try fixtures.pcm(seconds: 3)
        let m4a = try await fixtures.encoded(wav, to: format, kbps: format == .aac ? 256 : nil, name: "source.m4a")
        let original = try decode(m4a)
        let range = SampleRange(12_345, 100_000)
        let (output, plan) = try await export(m4a, format, segments: [range])
        #expect(plan.strategy == .passthrough)
        #expect(plan.verdict == .noReencode)
        let result = try decode(output).samples, expected = original.samples.frames([range], channels: 2)
        #expect(result.count == expected.count)
        if format == .alac {
            #expect(result == expected)
        } else {
            // The packets are copied untouched; Apple's AAC decoder rounds a
            // float ULP or two differently when it starts at the trim.
            #expect(result.maxDifference(expected) < 1e-5)
        }
    }

    // MARK: Encoding

    @Test("MP3 and AAC encodes keep the exact length (gapless)", arguments: [AudioFormat.mp3, .aac])
    func lossyLength(_ format: AudioFormat) async throws {
        defer { fixtures.cleanUp() }
        let wav = try fixtures.pcm(rate: 44_100, seconds: 2)
        let (output, plan) = try await export(wav, format, segments: [SampleRange(1_000, 80_000)])
        #expect(plan.verdict == .lossy)
        let file = try AVAudioFile(forReading: output)
        #expect(file.length == 79_000)
        // From the audio data: M4A files also reserve room for tags.
        let bitRate = try #require(try AudioEngine.inspect(url: output).bitRate)
        #expect(abs(Double(bitRate) / 1000 - 320) < 50)
    }

    @Test("MP3 at 96 kHz is resampled to 48 kHz")
    func resample() async throws {
        defer { fixtures.cleanUp() }
        let wav = try fixtures.pcm(rate: 96_000, seconds: 1)
        let (output, plan) = try await export(wav, .mp3)
        #expect(plan.sampleRate == 48_000)
        let file = try AVAudioFile(forReading: output)
        #expect(file.fileFormat.sampleRate == 48_000)
        #expect(abs(file.length - 48_000) <= 2)
    }

    @Test("Removing the middle of an MP3 re-encodes to the joined length")
    func mp3Join() async throws {
        defer { fixtures.cleanUp() }
        let wav = try fixtures.pcm(rate: 44_100, bits: 16, seconds: 3)
        let mp3 = try await fixtures.encoded(wav, to: .mp3, name: "join.mp3")
        let segments = [SampleRange(0, 30_000), SampleRange(60_000, 100_000)]
        let (output, plan) = try await export(mp3, .mp3, segments: segments)
        #expect(plan.strategy == .encode)
        #expect(try AVAudioFile(forReading: output).length == 70_000)
    }

    @Test("MP3 decoded to WAV is stored as float: identical to the decode")
    func mp3ToWav() async throws {
        defer { fixtures.cleanUp() }
        let wav = try fixtures.pcm(rate: 44_100, bits: 16, seconds: 2)
        let mp3 = try await fixtures.encoded(wav, to: .mp3, kbps: 128, name: "a.mp3")
        let (output, plan) = try await export(mp3, .wav)
        #expect(plan.isFloat)
        #expect(try decode(output).samples == decode(mp3).samples)
    }

    // MARK: Safety

    @Test("Export never overwrites the source")
    func protectsSource() async throws {
        defer { fixtures.cleanUp() }
        let wav = try fixtures.pcm(seconds: 1)
        let info = try AudioEngine.inspect(url: wav)
        let plan = try AudioPlanner.plan(info, AudioRequest(target: .wav, segments: [SampleRange(0, 100)]))
        await #expect(throws: OutputError.wouldOverwriteSource(wav.lastPathComponent)) {
            try await AudioEngine.export(wav, plan: plan, to: wav, overwrite: true)
        }
        #expect(try AudioEngine.inspect(url: wav).frames == 48_000)
    }

    @Test("FLAC size estimate is close to the real size")
    func estimate() async throws {
        defer { fixtures.cleanUp() }
        let wav = try fixtures.pcm(seconds: 3)
        let info = try AudioEngine.inspect(url: wav)
        let plan = try AudioPlanner.plan(info, AudioRequest(target: .flac, segments: [SampleRange(0, info.frames)]))
        let estimate = try await AudioEngine.estimatedSize(wav, plan: plan)
        let (output, _) = try await export(wav, .flac)
        let real = Int64(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
        #expect(abs(Double(estimate - real) / Double(real)) < 0.1)
    }
}
