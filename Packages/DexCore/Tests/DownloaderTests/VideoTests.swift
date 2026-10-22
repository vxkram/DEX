import AVFoundation
@testable import Downloader
import Foundation
import MediaModel
import Testing

@Suite("Video download")
struct VideoTests {
    @Test("Lists AV1 and H.264 qualities best first; skips VP9, HLS and muxed streams")
    func options() {
        let formats: [[String: Any]] = [
            ["format_id": "401", "ext": "mp4", "vcodec": "av01.0.13M.08", "acodec": "none", "height": 2160, "width": 3840, "fps": 60.0, "tbr": 8982.0, "filesize": 700_000_000.0, "protocol": "https", "dynamic_range": "SDR"],
            ["format_id": "399", "ext": "mp4", "vcodec": "av01.0.09M.08", "acodec": "none", "height": 1080, "width": 1920, "fps": 60.0, "tbr": 1568.0, "protocol": "https"],
            ["format_id": "299", "ext": "mp4", "vcodec": "avc1.64002a", "acodec": "none", "height": 1080, "width": 1920, "fps": 60.0, "tbr": 3248.0, "protocol": "https"],
            ["format_id": "312", "ext": "mp4", "vcodec": "avc1.64002A", "acodec": "none", "height": 1080, "fps": 60.0, "tbr": 7418.0, "protocol": "m3u8_native"],
            ["format_id": "315", "ext": "webm", "vcodec": "vp9", "acodec": "none", "height": 2160, "fps": 60.0, "tbr": 17174.0, "protocol": "https"],
            ["format_id": "18", "ext": "mp4", "vcodec": "avc1.42001E", "acodec": "mp4a.40.2", "height": 360, "protocol": "https"],
        ]
        let options = LinkDownloader.videoOptions(formats, audioBytes: 10_000_000).filter { !$0.isConverted }
        #expect(options.map(\.formatID) == ["401", "399", "299"])
        #expect(options[0].label == "2160p60")
        #expect(options[0].nickname == "4K")
        #expect(options[0].bytes == 710_000_000)
        #expect(options[2].isH264)
    }

    @Test("Offers AV1 sizes above YouTube's tallest H.264 as converted H.264")
    func convertedOptions() {
        let formats: [[String: Any]] = [
            ["format_id": "401", "ext": "mp4", "vcodec": "av01.0.13M.08", "acodec": "none", "height": 2160, "fps": 60.0, "tbr": 8982.0, "protocol": "https"],
            ["format_id": "701", "ext": "mp4", "vcodec": "av01.0.13M.10", "acodec": "none", "height": 2160, "fps": 60.0, "tbr": 12000.0, "protocol": "https", "dynamic_range": "HDR10"],
            ["format_id": "299", "ext": "mp4", "vcodec": "avc1.64002a", "acodec": "none", "height": 1080, "fps": 60.0, "tbr": 3248.0, "protocol": "https"],
        ]
        let options = LinkDownloader.videoOptions(formats, audioBytes: 1_000_000, duration: 100)
        let converted = options.filter(\.isConverted)
        #expect(converted.map(\.formatID) == ["401"])  // not the HDR one
        #expect(converted[0].codec == "H.264")
        #expect(converted[0].kbps == 45_000)
        #expect(converted[0].bytes == Int64(100 * 45_000 * 125 + 1_000_000))
        #expect(converted[0].id != options.first { $0.formatID == "401" && !$0.isConverted }?.id)
    }

    @Test("Converts the picture to H.264 and copies the audio")
    func convert() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dex-convert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("v.mp4")
        let audio = folder.appendingPathComponent("a.m4a")
        try await makeVideo(video, seconds: 2)
        try makeAudio(audio, seconds: 2.5)
        let output = folder.appendingPathComponent("converted.mp4")
        try await VideoConverter.convert(video: video, audio: audio, tags: AudioTags(title: "Forge"), kbps: 2_000, to: output) { _ in }
        let asset = AVURLAsset(url: output)
        let videoTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let audioTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        #expect(abs(try await asset.load(.duration).seconds - 2) < 0.1)
        #expect(try await videoTrack.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType) == kCMVideoCodecType_H264)
        #expect(try await audioTrack.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType) == kAudioFormatMPEG4AAC)
        let titles = try await asset.load(.commonMetadata).filter { $0.commonKey == .commonKeyTitle }
        #expect(try await titles.first?.load(.stringValue) == "Forge")
    }

    @Test("Joins a video and an audio stream without re-encoding, with the title")
    func join() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dex-video-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("v.mp4")
        let audio = folder.appendingPathComponent("a.m4a")
        try await makeVideo(video, seconds: 2)
        try makeAudio(audio, seconds: 2.5)
        let output = folder.appendingPathComponent("joined.mp4")
        try await VideoMuxer.join(video: video, audio: audio, tags: AudioTags(title: "Forge"), to: output)
        let asset = AVURLAsset(url: output)
        let videoTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(abs(try await asset.load(.duration).seconds - 2) < 0.1)
        // Passthrough: the H.264 samples are the same codec, not re-encoded.
        let subtype = try await videoTrack.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
        #expect(subtype == kCMVideoCodecType_H264)
        let titles = try await asset.load(.commonMetadata).filter { $0.commonKey == .commonKeyTitle }
        #expect(try await titles.first?.load(.stringValue) == "Forge")
    }

    func makeVideo(_ url: URL, seconds: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            memset(CVPixelBufferGetBaseAddress(buffer!), Int32(frame * 4 % 255), CVPixelBufferGetDataSize(buffer!))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    func makeAudio(_ url: URL, seconds: Double) throws {
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let value = Float(0.3 * sin(Double(i) * 2 * .pi * 440 / 44_100))
            buffer.floatChannelData![0][i] = value
            buffer.floatChannelData![1][i] = value
        }
        try file.write(from: buffer)
    }
}
