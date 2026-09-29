import MediaModel
import Testing

@Suite("Audio edit")
struct AudioEditTests {
    @Test("No edit keeps the whole file as one segment")
    func identity() {
        #expect(AudioEdit().segments(length: 1_000) == [SampleRange(0, 1_000)])
    }

    @Test("Trim keeps only its range, clamped to the file")
    func trim() {
        let edit = AudioEdit(trim: SampleRange(100, 5_000))
        #expect(edit.segments(length: 1_000) == [SampleRange(100, 1_000)])
    }

    @Test("Cuts remove sections; overlapping cuts merge")
    func cuts() {
        let edit = AudioEdit(trim: SampleRange(0, 1_000), removed: [SampleRange(200, 300), SampleRange(250, 400), SampleRange(900, 1_200)])
        #expect(edit.segments(length: 1_000) == [SampleRange(0, 200), SampleRange(400, 900)])
        #expect(edit.outputLength(length: 1_000) == 700)
    }

    @Test("Cutting everything leaves nothing")
    func cutAll() {
        #expect(AudioEdit(removed: [SampleRange(0, 1_000)]).segments(length: 1_000).isEmpty)
    }

    @Test("Split points divide the kept audio; a point inside a cut is ignored")
    func parts() {
        let edit = AudioEdit(trim: SampleRange(100, 1_000), removed: [SampleRange(400, 500)], splits: [50, 300, 450, 700, 700])
        #expect(edit.parts(length: 1_000) == [
            [SampleRange(100, 300)],
            [SampleRange(300, 400), SampleRange(500, 700)],
            [SampleRange(700, 1_000)],
        ])
    }
}

@Suite("Audio planner")
struct AudioPlannerTests {
    func info(_ codec: AudioCodec, type: String, depth: Int? = 16, float: Bool = false, rate: Double = 44_100,
              channels: Int = 2, tags: Bool = false, peak: Float? = nil) -> AudioInfo {
        AudioInfo(fileName: "a", fileSize: 1_000_000, typeIdentifier: type, codec: codec, codecName: codec.displayName,
                  sampleRate: rate, channels: channels, bitDepth: depth, isFloat: float, frames: 441_000,
                  bitRate: codec.isLossless ? nil : 256_000, hasTags: tags, peak: peak)
    }

    var wav: AudioInfo { info(.pcm, type: AudioFormat.wav.typeIdentifier) }
    var wav24: AudioInfo { info(.pcm, type: AudioFormat.wav.typeIdentifier, depth: 24) }
    var mp3: AudioInfo { info(.mp3, type: AudioFormat.mp3.typeIdentifier, depth: nil) }
    var aac: AudioInfo { info(.aac, type: "com.apple.m4a-audio", depth: nil) }

    func plan(_ source: AudioInfo, _ target: AudioFormat, bitRate: Int? = nil, segments: [SampleRange]? = nil) throws -> AudioPlan {
        try AudioPlanner.plan(source, AudioRequest(target: target, bitRate: bitRate, segments: segments ?? [SampleRange(0, source.frames)]))
    }

    @Test("Trimming an MP3 copies its frames")
    func mp3Trim() throws {
        let result = try plan(mp3, .mp3, segments: [SampleRange(1_000, 50_000)])
        #expect(result.strategy == .copyFrames)
        #expect(result.verdict == .noReencode)
    }

    @Test("Trimming AAC or ALAC in M4A is a passthrough")
    func m4aTrim() throws {
        #expect(try plan(aac, .aac, segments: [SampleRange(10, 20_000)]).strategy == .passthrough)
        let alac = info(.alac, type: "com.apple.m4a-audio", depth: 24)
        #expect(try plan(alac, .alac).verdict == .noReencode)
    }

    @Test("Cutting the middle out of an MP3 re-encodes and offers FLAC")
    func mp3Cut() throws {
        let result = try plan(mp3, .mp3, segments: [SampleRange(0, 1_000), SampleRange(5_000, 9_000)])
        #expect(result.strategy == .encode)
        #expect(result.verdict == .lossy)
        #expect(result.notes.contains(.joinNeedsReencode(.mp3)))
        #expect(result.losslessAlternative == .flac)
    }

    @Test("Choosing a bit rate for the same lossy format re-encodes")
    func explicitBitRate() throws {
        let result = try plan(mp3, .mp3, bitRate: 128)
        #expect(result.strategy == .encode)
        #expect(result.notes.contains(.lossyEncode(.mp3, kbps: 128)))
    }

    @Test("WAV to FLAC and ALAC keeps every sample", arguments: [AudioFormat.flac, .alac, .aiff])
    func losslessToLossless(_ target: AudioFormat) throws {
        let result = try plan(wav24, target, segments: [SampleRange(0, 1_000), SampleRange(2_000, 3_000)])
        #expect(result.verdict == .lossless)
        #expect(result.bitDepth == 24)
        #expect(result.notes == [.samplesCopied])
    }

    @Test("WAV to WAV copies samples without re-encoding")
    func wavCopy() throws {
        let result = try plan(wav, .wav, segments: [SampleRange(0, 1_000)])
        #expect(result.verdict == .noReencode)
        #expect(result.predictedBytes == Int64(1_000 * 2 * 2 + 44))
    }

    @Test("32-bit into FLAC loses bits; ALAC keeps them")
    func thirtyTwoBit() throws {
        let source = info(.pcm, type: AudioFormat.wav.typeIdentifier, depth: 32)
        let flac = try plan(source, .flac)
        #expect(flac.verdict == .lossy)
        #expect(flac.notes.contains(.bitDepthReduced(from: 32, to: 24)))
        #expect(flac.losslessAlternative == .wav)
        #expect(try plan(source, .alac).verdict == .lossless)
    }

    @Test("MP3 to WAV stores the decode as float: no additional loss")
    func lossyToWav() throws {
        let result = try plan(mp3, .wav)
        #expect(result.verdict == .lossless)
        #expect(result.isFloat)
        #expect(result.notes.contains(.noAdditionalLoss(bits: nil)))
    }

    @Test("MP3 with overs to FLAC clips; WAV is the lossless way out")
    func clipping() throws {
        let hot = info(.mp3, type: AudioFormat.mp3.typeIdentifier, depth: nil, peak: 1.2)
        let result = try plan(hot, .flac)
        #expect(result.notes.contains(.peaksClipped))
        #expect(result.losslessAlternative == .wav)
        #expect(try plan(info(.mp3, type: AudioFormat.mp3.typeIdentifier, depth: nil, peak: 0.9), .flac).verdict == .lossless)
    }

    @Test("Lossy into another lossy codec warns about generation loss")
    func generationLoss() throws {
        let result = try plan(aac, .mp3)
        #expect(result.notes.contains(.reencodedFrom(.aac)))
        #expect(result.bitRate == 320)
    }

    @Test("96 kHz to MP3 resamples to 48 kHz; 88.2 to 44.1; 6 channels mix down")
    func limits() throws {
        #expect(try plan(info(.pcm, type: AudioFormat.wav.typeIdentifier, rate: 96_000), .mp3).sampleRate == 48_000)
        #expect(try plan(info(.pcm, type: AudioFormat.wav.typeIdentifier, rate: 88_200), .aac).sampleRate == 44_100)
        let surround = try plan(info(.pcm, type: AudioFormat.wav.typeIdentifier, channels: 6), .mp3)
        #expect(surround.channels == 2)
        #expect(surround.notes.contains(.downmixed(from: 6, to: 2)))
        #expect(try plan(info(.pcm, type: AudioFormat.wav.typeIdentifier, channels: 6), .aac).channels == 6)
    }

    @Test("Tags are flagged when they won't survive")
    func tags() throws {
        let tagged = info(.mp3, type: AudioFormat.mp3.typeIdentifier, depth: nil, tags: true)
        #expect(!(try plan(tagged, .mp3).notes.contains(.tagsNotCopied)))
        #expect(try plan(tagged, .wav).notes.contains(.tagsNotCopied))
        let written = AudioRequest(target: .flac, segments: [SampleRange(0, 10)], tags: AudioTags(title: "A"))
        #expect(!(try AudioPlanner.plan(tagged, written).notes.contains(.tagsNotCopied)))
    }

    @Test("Nothing left to export is an error")
    func empty() {
        #expect(throws: AudioPlanError.nothingToExport) { try plan(wav, .wav, segments: []) }
    }
}
