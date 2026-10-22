import AudioTagging
import AVFoundation
import Foundation
import MediaModel

/// Joins a video-only and an audio-only stream into one MP4, without
/// re-encoding either (AVFoundation passthrough).
///
/// YouTube's split streams claim twice their real length in their headers
/// (yt-dlp normally fixes that with ffmpeg), so each stream's real end is
/// measured from its last sample and only that much is joined.
public enum VideoMuxer {
    public static func join(video: URL, audio: URL, tags: AudioTags, to output: URL) async throws {
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first
        else { throw LinkDownloadError.failed("The downloaded streams couldn't be read.") }
        guard try await videoAsset.load(.isPlayable) else {
            throw LinkDownloadError.failed("This Mac can't play that video format.")
        }
        var videoEnd = try await realEnd(videoTrack)
        if videoEnd == nil { videoEnd = try await videoAsset.load(.duration) }
        var audioEnd = try await realEnd(audioTrack)
        if audioEnd == nil { audioEnd = try await audioAsset.load(.duration) }
        let duration = CMTimeMinimum(videoEnd!, audioEnd!)

        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw LinkDownloadError.failed("The video couldn't be assembled.") }
        let range = CMTimeRange(start: .zero, duration: duration)
        try compositionVideo.insertTimeRange(range, of: videoTrack, at: .zero)
        try compositionAudio.insertTimeRange(range, of: audioTrack, at: .zero)
        compositionVideo.preferredTransform = try await videoTrack.load(.preferredTransform)

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw LinkDownloadError.failed("The video couldn't be assembled without re-encoding.")
        }
        session.metadata = AudioTagging.metadataItems(tags)
        try? FileManager.default.removeItem(at: output)
        do {
            try await session.export(to: output, as: .mp4)
        } catch {
            throw LinkDownloadError.failed("Joining the video and audio failed: \(error.localizedDescription)")
        }

        // Check: two tracks, the planned length.
        let result = AVURLAsset(url: output)
        let tracks = try await result.load(.tracks)
        let length = try await result.load(.duration)
        guard tracks.count == 2, abs(length.seconds - duration.seconds) < 0.5 else {
            try? FileManager.default.removeItem(at: output)
            throw LinkDownloadError.failed("The joined video didn't check out, so it wasn't kept.")
        }
    }

    /// Where a track's samples really end (its last sample in presentation
    /// order), whatever its header says.
    static func realEnd(_ track: AVAssetTrack) async throws -> CMTime? {
        guard try await track.load(.canProvideSampleCursors), let cursor = track.makeSampleCursorAtLastSampleInDecodeOrder() else { return nil }
        var end = CMTimeAdd(cursor.presentationTimeStamp, cursor.currentSampleDuration)
        // With B-frames the last decoded sample isn't the last shown.
        for _ in 0..<32 {
            guard cursor.stepInDecodeOrder(byCount: -1) != 0 else { break }
            end = CMTimeMaximum(end, CMTimeAdd(cursor.presentationTimeStamp, cursor.currentSampleDuration))
        }
        return end
    }
}
