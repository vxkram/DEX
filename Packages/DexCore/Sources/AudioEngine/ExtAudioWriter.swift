import AudioToolbox
import AVFoundation
import MediaModel

/// Writes WAV, AIFF, FLAC, ALAC and AAC through ExtAudioFile with an
/// explicit file type and stream format. `AVAudioFile` can't do this for
/// FLAC: it stores 16-bit sources as 24-bit.
final class ExtAudioWriter {
    private var file: ExtAudioFileRef?

    /// `client` is the format of the buffers passed to `write`.
    init(url: URL, plan: AudioPlan, client: AVAudioFormat) throws {
        var format = Self.streamFormat(for: plan)
        var ref: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(
            url as CFURL, Self.fileType(plan.request.target), &format, nil, AudioFileFlags.eraseFile.rawValue, &ref
        )
        guard status == noErr, let ref else {
            throw AudioExportError.encoderFailed("couldn't create the \(plan.request.target.displayName) file (\(status))")
        }
        file = ref
        if plan.channels > 2, let layout = client.channelLayout {
            ExtAudioFileSetProperty(ref, kExtAudioFileProperty_FileChannelLayout,
                                    UInt32(MemoryLayout<AudioChannelLayout>.size), layout.layout)
        }
        var clientFormat = client.streamDescription.pointee
        try check(ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat))
        if plan.request.target == .aac { try configureAAC(kbps: plan.bitRate ?? AudioRequest.maximumBitRate) }
    }

    deinit { if let file { ExtAudioFileDispose(file) } }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let file else { return }
        try check(ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList))
    }

    /// Disposing flushes the encoder and writes the headers.
    func finish() throws {
        guard let file else { return }
        self.file = nil
        try check(ExtAudioFileDispose(file))
    }

    private func configureAAC(kbps: Int) throws {
        guard let file else { return }
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter))
        guard let converter else { return }
        var bitRate = UInt32(kbps * 1000)
        try check(AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitRate))
        var quality = UInt32(kAudioConverterQuality_Max)
        AudioConverterSetProperty(converter, kAudioConverterCodecQuality, UInt32(MemoryLayout<UInt32>.size), &quality)
        // Tells ExtAudioFile to pick up the converter's new settings.
        var config: UnsafeRawPointer?
        try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig,
                                          UInt32(MemoryLayout<UnsafeRawPointer?>.size), &config))
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioExportError.encoderFailed("audio write error \(status)") }
    }

    private static func fileType(_ format: AudioFormat) -> AudioFileTypeID {
        switch format {
        case .wav: kAudioFileWAVEType
        case .aiff: kAudioFileAIFFType
        case .flac: kAudioFileFLACType
        case .alac, .aac: kAudioFileM4AType
        case .mp3: kAudioFileMP3Type
        }
    }

    static func streamFormat(for plan: AudioPlan) -> AudioStreamBasicDescription {
        let channels = UInt32(plan.channels)
        var format = AudioStreamBasicDescription()
        format.mSampleRate = plan.sampleRate
        format.mChannelsPerFrame = channels
        let bits = UInt32(plan.isFloat ? 32 : (plan.bitDepth ?? 24))
        switch plan.request.target {
        case .wav, .aiff:
            format.mFormatID = kAudioFormatLinearPCM
            format.mFormatFlags = (plan.isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger)
                | kAudioFormatFlagIsPacked | (plan.request.target == .aiff ? kAudioFormatFlagIsBigEndian : 0)
            format.mBitsPerChannel = bits
            format.mBytesPerFrame = (bits + 7) / 8 * channels
            format.mFramesPerPacket = 1
            format.mBytesPerPacket = format.mBytesPerFrame
        case .flac, .alac:
            format.mFormatID = plan.request.target == .flac ? kAudioFormatFLAC : kAudioFormatAppleLossless
            // The source bit depth lives in the flags: 1 = 16, 2 = 20, 3 = 24, 4 = 32.
            format.mFormatFlags = switch bits {
            case ...16: 1
            case ...20: 2
            case ...24: 3
            default: 4
            }
        case .aac:
            format.mFormatID = kAudioFormatMPEG4AAC
        case .mp3:
            break
        }
        return format
    }
}
