import AudioEngine
import AudioTagging
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MediaModel
import Testing

@Suite("Audio tags", .serialized)
struct TaggingTests {
    let fixtures: AudioFixtures

    init() throws { fixtures = try AudioFixtures() }

    /// A small real JPEG.
    func cover() -> Artwork {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.96, green: 0.36, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return Artwork(data: data as Data)
    }

    var tags: AudioTags { AudioTags(title: "Forge Song ✦", artist: "DEX", album: "Tests", artwork: cover()) }

    func export(_ source: URL, _ target: AudioFormat, segments: [SampleRange]? = nil, tags: AudioTags?) async throws -> (URL, AudioPlan) {
        let info = try AudioEngine.inspect(url: source)
        let plan = try AudioPlanner.plan(info, AudioRequest(target: target, segments: segments ?? [SampleRange(0, info.frames)], tags: tags))
        let output = fixtures.directory.appendingPathComponent("tagged-\(UUID().uuidString).\(target.fileExtension)")
        try await AudioEngine.export(source, plan: plan, to: output)
        return (output, plan)
    }

    @Test("Tags and artwork are written and read back", arguments: [AudioFormat.mp3, .flac, .aac, .alac])
    func roundTrip(_ format: AudioFormat) async throws {
        defer { fixtures.cleanUp() }
        let wav = try fixtures.pcm(rate: 44_100, bits: 16, seconds: 2)
        let (output, _) = try await export(wav, format, tags: tags)
        let read = await AudioTagging.tags(of: output)
        #expect(read.title == tags.title)
        #expect(read.artist == tags.artist)
        #expect(read.album == tags.album)
        #expect(read.artwork?.data == tags.artwork?.data)
        if format == .flac { #expect(try decode(output).samples == decode(wav).samples) }
    }

    @Test("Adding artwork to an MP3 trim keeps the audio bit-identical")
    func mp3ArtworkOnCopy() async throws {
        defer { fixtures.cleanUp() }
        let wav = try fixtures.pcm(rate: 44_100, bits: 16, seconds: 3)
        let mp3 = try await fixtures.encoded(wav, to: .mp3, kbps: 192, name: "plain.mp3")
        let range = SampleRange(10_000, 90_000)
        let (output, plan) = try await export(mp3, .mp3, segments: [range], tags: tags)
        #expect(plan.strategy == .copyFrames)
        #expect(try decode(output).samples == decode(mp3).samples.frames([range], channels: 2))
        #expect(await AudioTagging.tags(of: output).artwork?.data == tags.artwork?.data)
        // Retagging keeps frames it doesn't manage.
        let retagged = await AudioTagging.tags(of: output)
        #expect(retagged.title == tags.title)
    }

    @Test("Unchanged tags on a copy leave the file as the plain cut")
    func unchangedTags() async throws {
        defer { fixtures.cleanUp() }
        let wav = try fixtures.pcm(rate: 44_100, bits: 16, seconds: 2)
        let mp3 = try await fixtures.encoded(wav, to: .mp3, name: "none.mp3")
        let (withTags, _) = try await export(mp3, .mp3, segments: [SampleRange(0, 40_000)], tags: AudioTags())
        let (without, _) = try await export(mp3, .mp3, segments: [SampleRange(0, 40_000)], tags: nil)
        #expect(try Data(contentsOf: withTags) == Data(contentsOf: without))
    }
}
