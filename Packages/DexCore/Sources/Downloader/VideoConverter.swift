import AudioTagging
import AVFoundation
import Foundation
import MediaModel

/// Makes an H.264 MP4 from a video stream YouTube only has as AV1 (4K,
/// 1440p): the picture is decoded and encoded again with the Mac's
/// hardware H.264 encoder at a high bit rate; the audio is copied as it is.
/// Used only when the user picks a "Converted" quality.
public enum VideoConverter {
    /// H.264 bit rate for a converted picture, kbit/s: around YouTube's
    /// own upload recommendation, so the second encode costs little.
    public static func bitRate(height: Int, fps: Int) -> Int {
        let high = fps > 30
        switch height {
        case 4320...: return high ? 120_000 : 80_000
        case 2160...: return high ? 45_000 : 35_000
        case 1440...: return high ? 24_000 : 16_000
        default: return high ? 12_000 : 8_000
        }
    }

    public static func convert(
        video: URL, audio: URL, tags: AudioTags, kbps: Int, to output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first
        else { throw LinkDownloadError.failed("The downloaded streams couldn't be read.") }
        var videoEnd = try await VideoMuxer.realEnd(videoTrack)
        if videoEnd == nil { videoEnd = try await videoAsset.load(.duration) }
        var audioEnd = try await VideoMuxer.realEnd(audioTrack)
        if audioEnd == nil { audioEnd = try await audioAsset.load(.duration) }
        let range = CMTimeRange(start: .zero, duration: CMTimeMinimum(videoEnd!, audioEnd!))

        let size = try await videoTrack.load(.naturalSize)
        let fps = try await videoTrack.load(.nominalFrameRate)
        let transform = try await videoTrack.load(.preferredTransform)
        guard let audioFormat = try await audioTrack.load(.formatDescriptions).first else {
            throw LinkDownloadError.failed("The audio stream couldn't be read.")
        }

        let videoReader = try AVAssetReader(asset: videoAsset)
        videoReader.timeRange = range
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        videoReader.add(videoOutput)
        let audioReader = try AVAssetReader(asset: audioAsset)
        audioReader.timeRange = range
        // nil settings: the AAC packets come out compressed, to be copied.
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        audioReader.add(audioOutput)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.metadata = AudioTagging.metadataItems(tags)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: kbps * 1000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ] as [String: Any],
        ])
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw LinkDownloadError.failed("This Mac can't encode H.264 at \(Int(size.width))×\(Int(size.height)).")
        }
        writer.add(videoInput)
        writer.add(audioInput)

        guard videoReader.startReading(), audioReader.startReading() else {
            throw LinkDownloadError.failed("This Mac can't decode the downloaded video (\(videoReader.error?.localizedDescription ?? "unknown")).")
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let total = range.duration.seconds
        let video = Pump(input: videoInput, output: videoOutput) { time in progress(min(time.seconds / max(total, 1), 1)) }
        let sound = Pump(input: audioInput, output: audioOutput) { _ in }
        do {
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await video.run(label: "video") }
                    group.addTask { try await sound.run(label: "audio") }
                    try await group.waitForAll()
                }
            } onCancel: {
                video.cancel()
                sound.cancel()
            }
        } catch {
            writer.cancelWriting()
            videoReader.cancelReading()
            audioReader.cancelReading()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        try Task.checkCancellation()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw LinkDownloadError.failed("Converting to H.264 failed: \(writer.error?.localizedDescription ?? "unknown error").")
        }

        let result = AVURLAsset(url: output)
        guard try await result.load(.tracks).count == 2,
              abs(try await result.load(.duration).seconds - total) < 0.5
        else {
            try? FileManager.default.removeItem(at: output)
            throw LinkDownloadError.failed("The converted video didn't check out, so it wasn't kept.")
        }
    }
}

/// Feeds one reader output into one writer input on its own queue.
private final class Pump: @unchecked Sendable {
    private let input: AVAssetWriterInput
    private let output: AVAssetReaderOutput
    private let progress: (CMTime) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false

    init(input: AVAssetWriterInput, output: AVAssetReaderOutput, progress: @escaping (CMTime) -> Void) {
        self.input = input
        self.output = output
        self.progress = progress
    }

    func cancel() { lock.withLock { cancelled = true } }

    func run(label: String) async throws {
        let queue = DispatchQueue(label: "com.dex.convert.\(label)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while input.isReadyForMoreMediaData {
                    if lock.withLock({ cancelled || finished }) { break }
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        finish(continuation, nil)
                        return
                    }
                    progress(CMSampleBufferGetPresentationTimeStamp(sample))
                    if !input.append(sample) {
                        finish(continuation, LinkDownloadError.failed("Writing the \(label) failed."))
                        return
                    }
                }
                if lock.withLock({ cancelled }) {
                    input.markAsFinished()
                    finish(continuation, CancellationError())
                }
            }
        }
    }

    private func finish(_ continuation: CheckedContinuation<Void, Error>, _ error: Error?) {
        let first = lock.withLock { () -> Bool in
            defer { finished = true }
            return !finished
        }
        guard first else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
