import AVFoundation
import CLame
import Foundation

/// Encodes float PCM to MP3 with LAME (constant bit rate, LAME's
/// high-quality search) and writes the gapless Info header at the end, so
/// decoders that honour it play exactly the samples that went in.
final class MP3Writer {
    private let lame: OpaquePointer
    private let handle: FileHandle
    private let channels: Int
    private var output = [UInt8](repeating: 0, count: 1 << 18)

    static var version: String { String(cString: get_lame_short_version()) }

    /// `vbrQuality` (0 best … 9) switches to LAME's VBR mode; tests use it
    /// to make VBR fixtures.
    init(url: URL, sampleRate: Double, channels: Int, kbps: Int, vbrQuality: Int32? = nil) throws {
        guard let lame = lame_init() else { throw AudioExportError.encoderFailed("MP3 encoder didn't start") }
        self.lame = lame
        self.channels = channels
        lame_set_num_channels(lame, Int32(channels))
        lame_set_in_samplerate(lame, Int32(sampleRate))
        lame_set_out_samplerate(lame, Int32(sampleRate))
        if let vbrQuality {
            lame_set_VBR(lame, vbr_default)
            lame_set_VBR_q(lame, vbrQuality)
        } else {
            lame_set_VBR(lame, vbr_off)
            lame_set_brate(lame, Int32(kbps))
        }
        lame_set_mode(lame, channels == 1 ? MONO : JOINT_STEREO)
        // 2 is LAME's recommended high quality; 0 is much slower for no
        // audible gain.
        lame_set_quality(lame, 2)
        lame_set_bWriteVbrTag(lame, 1)
        guard lame_init_params(lame) >= 0 else {
            lame_close(lame)
            throw AudioExportError.encoderFailed("MP3 can't be encoded at \(Int(sampleRate)) Hz and \(kbps) kbit/s")
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let handle = try? FileHandle(forWritingTo: url) else {
            lame_close(lame)
            throw AudioExportError.encoderFailed("couldn't create the MP3 file")
        }
        self.handle = handle
    }

    deinit {
        lame_close(lame)
        try? handle.close()
    }

    /// Float samples, non-interleaved, one or two channels.
    func write(_ buffer: AVAudioPCMBuffer) throws {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return }
        let needed = frames * 5 / 4 + 7200
        if output.count < needed { output = [UInt8](repeating: 0, count: needed) }
        let right = channels > 1 ? data[1] : data[0]
        let written = lame_encode_buffer_ieee_float(lame, data[0], right, Int32(frames), &output, Int32(output.count))
        guard written >= 0 else { throw AudioExportError.encoderFailed("MP3 encoding failed (\(written))") }
        try handle.write(contentsOf: output[0..<Int(written)])
    }

    func finish() throws {
        let written = lame_encode_flush(lame, &output, Int32(output.count))
        guard written >= 0 else { throw AudioExportError.encoderFailed("MP3 encoding failed (\(written))") }
        try handle.write(contentsOf: output[0..<Int(written)])
        // LAME reserved the first frame for the Info header; fill it in now
        // that the frame count and encoder delay/padding are known.
        var tag = [UInt8](repeating: 0, count: 2_880)
        let size = lame_get_lametag_frame(lame, &tag, tag.count)
        if size > 0 && size <= tag.count {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: tag[0..<size])
        }
        try handle.close()
    }
}
