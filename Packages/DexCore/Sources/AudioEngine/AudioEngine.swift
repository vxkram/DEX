import Accelerate
import AudioToolbox
import AVFoundation
import Foundation
import JobSystem
import MediaModel
import UniformTypeIdentifiers

public enum AudioInspectError: Error, Equatable, CustomStringConvertible {
    case fileNotFound(String)
    case emptyFile(String)
    case notAudio(String)

    public var description: String {
        switch self {
        case .fileNotFound(let name): "“\(name)” could not be found."
        case .emptyFile(let name): "“\(name)” is empty (0 bytes)."
        case .notAudio(let name): "“\(name)” isn't an audio format DEX can read."
        }
    }
}

/// Min/max outline of the audio for drawing, at a fixed number of frames
/// per bucket so it can be shown at any zoom.
public struct Waveform: Sendable, Equatable {
    public let framesPerBucket: Int
    public let mins: [Float]
    public let maxs: [Float]
    /// Loudness (RMS over all channels) per bucket: what the bars show,
    /// because peaks of a loud master all sit at full scale.
    public let rms: [Float]
    /// Highest absolute sample value in the file.
    public let peak: Float
    /// The loudest bucket, for scaling bars the same at every zoom.
    public let maxRMS: Float
    public let frames: Int64

    public init(framesPerBucket: Int, mins: [Float], maxs: [Float], rms: [Float], peak: Float, frames: Int64) {
        self.framesPerBucket = framesPerBucket
        self.mins = mins
        self.maxs = maxs
        self.rms = rms
        self.peak = peak
        self.maxRMS = rms.max() ?? 0
        self.frames = frames
    }

    /// Loudness over a span of buckets (the RMS of their RMS values).
    public func level(buckets: Range<Int>) -> Float {
        let range = buckets.clamped(to: 0..<rms.count)
        guard !range.isEmpty else { return 0 }
        var meanSquare: Float = 0
        rms.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + range.lowerBound, 1, &meanSquare, vDSP_Length(range.count)) }
        return meanSquare.squareRoot()
    }

    /// Min and max over a span of buckets.
    public func extent(buckets: Range<Int>) -> (min: Float, max: Float) {
        let range = buckets.clamped(to: 0..<mins.count)
        guard !range.isEmpty else { return (0, 0) }
        var low: Float = 0
        var high: Float = 0
        mins.withUnsafeBufferPointer { vDSP_minv($0.baseAddress! + range.lowerBound, 1, &low, vDSP_Length(range.count)) }
        maxs.withUnsafeBufferPointer { vDSP_maxv($0.baseAddress! + range.lowerBound, 1, &high, vDSP_Length(range.count)) }
        return (low, high)
    }
}

public enum AudioEngine {
    /// Whether the file is audio (by its type), so the app can route it.
    public static func isAudio(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .audio) ?? false
    }

    public static func inspectAsync(url: URL) async throws -> AudioInfo {
        try await MediaWork.run { _ in try inspect(url: url) }
    }

    /// Reads codec, sample format, length and tags without decoding.
    public static func inspect(url: URL) throws -> AudioInfo {
        let name = url.lastPathComponent
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else {
            throw AudioInspectError.fileNotFound(name)
        }
        let fileSize = Int64(values.fileSize ?? 0)
        if fileSize == 0 { throw AudioInspectError.emptyFile(name) }

        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else {
            throw AudioInspectError.notAudio(name)
        }
        defer { AudioFileClose(fileID) }
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else {
            throw AudioInspectError.notAudio(name)
        }

        let fileType: AudioFileTypeID = property(fileID, kAudioFilePropertyFileFormat) ?? 0
        let format = file.fileFormat.streamDescription.pointee
        let codec = codec(for: format.mFormatID)
        let sourceDepth: Int32? = property(fileID, kAudioFilePropertySourceBitDepth)
        let isFloat = codec == .pcm && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bitDepth: Int? = switch codec {
        case .pcm: Int(format.mBitsPerChannel)
        case .flac, .alac: losslessDepth(flags: format.mFormatFlags) ?? sourceDepth.map { Int(abs($0)) }
        default: nil
        }
        let bitRate: UInt32? = property(fileID, kAudioFilePropertyBitRate)

        return AudioInfo(
            fileName: name,
            fileSize: fileSize,
            typeIdentifier: typeIdentifier(fileType, url: url),
            codec: codec,
            codecName: codecName(format.mFormatID),
            sampleRate: format.mSampleRate,
            channels: Int(format.mChannelsPerFrame),
            bitDepth: bitDepth,
            isFloat: isFloat,
            frames: file.length,
            bitRate: bitRate.flatMap { $0 > 0 ? Int($0) : nil },
            hasTags: hasTags(fileID)
        )
    }

    /// Decodes the whole file once to draw it and find its peak.
    public static func waveform(url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Waveform {
        try await MediaWork.run { token in
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = file.length
            // Fine enough to zoom in on a few milliseconds; a 3-hour file
            // stays around 16 MB.
            let perBucket = max(128, Int((frames + 1_999_999) / 2_000_000))
            let bucketCount = Int((frames + Int64(perBucket) - 1) / Int64(perBucket))
            var mins = [Float](repeating: 0, count: bucketCount)
            var maxs = [Float](repeating: 0, count: bucketCount)
            var rms = [Float](repeating: 0, count: bucketCount)
            var peak: Float = 0
            let chunk = AVAudioFrameCount(perBucket * max(1, 65_536 / perBucket))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else {
                throw AudioInspectError.notAudio(url.lastPathComponent)
            }
            var bucket = 0
            while file.framePosition < frames {
                try token.check()
                try file.read(into: buffer, frameCount: chunk)
                let count = Int(buffer.frameLength)
                if count == 0 { break }
                let channels = Int(buffer.format.channelCount)
                var offset = 0
                while offset < count, bucket < bucketCount {
                    let span = min(perBucket, count - offset)
                    var low = Float.greatestFiniteMagnitude
                    var high = -Float.greatestFiniteMagnitude
                    var squares: Float = 0
                    for channel in 0..<channels {
                        let samples = buffer.floatChannelData![channel] + offset
                        var channelLow: Float = 0
                        var channelHigh: Float = 0
                        vDSP_minv(samples, 1, &channelLow, vDSP_Length(span))
                        vDSP_maxv(samples, 1, &channelHigh, vDSP_Length(span))
                        var channelSquares: Float = 0
                        vDSP_measqv(samples, 1, &channelSquares, vDSP_Length(span))
                        squares += channelSquares
                        low = min(low, channelLow)
                        high = max(high, channelHigh)
                    }
                    mins[bucket] = low
                    maxs[bucket] = high
                    rms[bucket] = (squares / Float(channels)).squareRoot()
                    peak = max(peak, -low, high)
                    offset += span
                    bucket += 1
                }
                progress?(Double(file.framePosition) / Double(max(frames, 1)))
            }
            return Waveform(framesPerBucket: perBucket, mins: mins, maxs: maxs, rms: rms, peak: peak, frames: frames)
        }
    }

    // MARK: - Private

    private static func property<T>(_ file: AudioFileID, _ id: AudioFilePropertyID) -> T? {
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioFileGetProperty(file, id, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    static func codec(for formatID: AudioFormatID) -> MediaModel.AudioCodec {
        switch formatID {
        case kAudioFormatLinearPCM: .pcm
        case kAudioFormatFLAC: .flac
        case kAudioFormatAppleLossless: .alac
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD,
             kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_ELD_V2, kAudioFormatMPEG4AAC_ELD_SBR: .aac
        case kAudioFormatMPEGLayer3: .mp3
        default: .other
        }
    }

    private static func codecName(_ formatID: AudioFormatID) -> String {
        switch formatID {
        case kAudioFormatLinearPCM: "PCM"
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatAppleLossless: "Apple Lossless (ALAC)"
        case kAudioFormatMPEG4AAC: "AAC"
        case kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: "HE-AAC"
        case kAudioFormatMPEGLayer3: "MP3"
        case kAudioFormatMPEGLayer2: "MP2"
        case kAudioFormatOpus: "Opus"
        case kAudioFormatAC3: "AC-3"
        case kAudioFormatEnhancedAC3: "E-AC-3"
        case kAudioFormatULaw: "µ-law"
        case kAudioFormatALaw: "A-law"
        case 0x766F_7262: "Vorbis"  // 'vorb'
        default:
            String(bytes: [24, 16, 8, 0].map { UInt8(formatID >> $0 & 0xFF) }, encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces) ?? "Unknown"
        }
    }

    /// FLAC and ALAC store the source bit depth in the format flags.
    private static func losslessDepth(flags: AudioFormatFlags) -> Int? {
        switch flags {
        case 1: 16
        case 2: 20
        case 3: 24
        case 4: 32
        default: nil
        }
    }

    private static func typeIdentifier(_ fileType: AudioFileTypeID, url: URL) -> String {
        switch fileType {
        case kAudioFileWAVEType, kAudioFileRF64Type, kAudioFileBW64Type: AudioFormat.wav.typeIdentifier
        case kAudioFileAIFFType: AudioFormat.aiff.typeIdentifier
        case kAudioFileAIFCType: "public.aifc-audio"
        case kAudioFileFLACType: AudioFormat.flac.typeIdentifier
        case kAudioFileM4AType: "com.apple.m4a-audio"
        case kAudioFileMPEG4Type: "public.mpeg-4-audio"
        case kAudioFileMP3Type: AudioFormat.mp3.typeIdentifier
        case kAudioFileCAFType: "com.apple.coreaudio-format"
        default: UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.audio"
        }
    }

    /// Title, artist and the like (not technical entries such as duration).
    private static func hasTags(_ file: AudioFileID) -> Bool {
        var size = UInt32(MemoryLayout<CFDictionary?>.size)
        var dictionary: Unmanaged<CFDictionary>?
        guard AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &dictionary) == noErr,
              let info = dictionary?.takeRetainedValue() as? [String: Any]
        else { return false }
        let userKeys: Set<String> = [
            kAFInfoDictionary_Title, kAFInfoDictionary_Artist, kAFInfoDictionary_Album, kAFInfoDictionary_Genre,
            kAFInfoDictionary_Year, kAFInfoDictionary_Comments, kAFInfoDictionary_Composer,
            kAFInfoDictionary_TrackNumber, kAFInfoDictionary_Copyright, kAFInfoDictionary_Lyricist,
        ]
        return info.keys.contains(where: userKeys.contains)
    }
}
