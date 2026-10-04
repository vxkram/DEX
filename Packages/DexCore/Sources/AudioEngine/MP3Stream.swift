import Foundation

public enum MP3Error: Error, Equatable, CustomStringConvertible {
    case notMP3
    case unsupported(String)

    public var description: String {
        switch self {
        case .notMP3: "This file doesn't contain MPEG Layer III audio frames."
        case .unsupported(let detail): "This MP3 can't be cut without re-encoding: \(detail)."
        }
    }
}

/// The 4-byte header in front of every MPEG audio frame (Layer III only).
struct MP3Header: Equatable {
    let raw: UInt32

    enum Version { case mpeg1, mpeg2, mpeg25 }

    private static let bitRates: [[Int]] = [
        [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],  // MPEG-1
        [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],  // MPEG-2 and 2.5
    ]
    private static let sampleRates: [Version: [Int]] = [
        .mpeg1: [44_100, 48_000, 32_000], .mpeg2: [22_050, 24_000, 16_000], .mpeg25: [11_025, 12_000, 8_000],
    ]

    init?(_ raw: UInt32) {
        guard raw >> 21 == 0x7FF,  // sync
              (raw >> 19) & 3 != 1,  // reserved version
              (raw >> 17) & 3 == 1,  // Layer III
              (1...14).contains((raw >> 12) & 15),  // no free format, no bad index
              (raw >> 10) & 3 != 3  // reserved sample rate
        else { return nil }
        self.raw = raw
    }

    init?(_ data: Data, at offset: Int) {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let b = data.startIndex + offset
        self.init(UInt32(data[b]) << 24 | UInt32(data[b + 1]) << 16 | UInt32(data[b + 2]) << 8 | UInt32(data[b + 3]))
    }

    var version: Version {
        switch (raw >> 19) & 3 {
        case 3: .mpeg1
        case 2: .mpeg2
        default: .mpeg25
        }
    }

    var bitRateIndex: Int { Int((raw >> 12) & 15) }
    var bitRate: Int { Self.bitRates[version == .mpeg1 ? 0 : 1][bitRateIndex] * 1000 }
    var sampleRate: Int { Self.sampleRates[version]![Int((raw >> 10) & 3)] }
    var hasPadding: Bool { (raw >> 9) & 1 == 1 }
    var hasCRC: Bool { (raw >> 16) & 1 == 0 }
    var isMono: Bool { (raw >> 6) & 3 == 3 }
    var samplesPerFrame: Int { version == .mpeg1 ? 1152 : 576 }
    var frameSize: Int { (version == .mpeg1 ? 144 : 72) * bitRate / sampleRate + (hasPadding ? 1 : 0) }
    var sideInfoSize: Int { version == .mpeg1 ? (isMono ? 17 : 32) : (isMono ? 9 : 17) }
    /// Bytes before the main data: header, CRC and side information.
    var overhead: Int { 4 + (hasCRC ? 2 : 0) + sideInfoSize }
    /// Largest backwards reach of the bit reservoir.
    var maxReservoir: Int { version == .mpeg1 ? 511 : 255 }

    /// Frames in one stream must agree on these to be the same stream.
    func isCompatible(with other: MP3Header) -> Bool {
        raw & 0xFFFE_0C00 == other.raw & 0xFFFE_0C00 && isMono == other.isMono
    }

    /// The same stream parameters with another bit rate, no padding and no CRC.
    func with(bitRateIndex index: Int) -> MP3Header {
        MP3Header((raw & ~(UInt32(15) << 12) & ~(UInt32(1) << 9) | UInt32(1) << 16) | UInt32(index) << 12)!
    }

    var bytes: [UInt8] { [UInt8(raw >> 24), UInt8(raw >> 16 & 0xFF), UInt8(raw >> 8 & 0xFF), UInt8(raw & 0xFF)] }
}

struct MP3Frame {
    let offset: Int
    let header: MP3Header
    var size: Int { header.frameSize }
    var mainDataSize: Int { size - header.overhead }
}

/// An MP3 file split into its parts, so it can be cut on frame boundaries
/// without decoding: ID3 tags, the gapless (Xing/LAME) header and the
/// audio frames.
///
/// Sample positions follow Apple's decoder, which honours the LAME
/// header: sample 0 is the first sample after the encoder delay.
struct MP3Stream {
    let data: Data
    let id3v2: Range<Int>?
    let id3v1: Range<Int>?
    let frames: [MP3Frame]
    /// Samples to skip at the start and end (from the LAME header).
    let delay: Int
    let padding: Int
    /// The original LAME header's bytes (encoder string onwards), reused
    /// so the output still names the encoder that made the frames.
    let lameTag: Data?

    var samplesPerFrame: Int { frames.first?.header.samplesPerFrame ?? 1152 }
    var decodedLength: Int64 { Int64(frames.count * samplesPerFrame - delay - padding) }

    init(data: Data) throws {
        self.data = data
        var position = 0
        if data.count >= 10, data.prefix(3) == Data("ID3".utf8) {
            let b = data.startIndex
            let size = Int(data[b + 6]) << 21 | Int(data[b + 7]) << 14 | Int(data[b + 8]) << 7 | Int(data[b + 9])
            let footer = data[b + 5] & 0x10 != 0 ? 10 : 0
            position = min(10 + size + footer, data.count)
            id3v2 = 0..<position
        } else {
            id3v2 = nil
        }
        var end = data.count
        if end >= 128, data[data.startIndex + end - 128..<data.startIndex + end - 125] == Data("TAG".utf8) {
            id3v1 = (end - 128)..<end
            end -= 128
        } else {
            id3v1 = nil
        }

        var frames: [MP3Frame] = []
        var reference: MP3Header?
        while position + 4 <= end {
            // A frame counts when the next one follows it (or it ends the
            // stream), which rules out false syncs inside other data.
            if let header = MP3Header(data, at: position), reference.map(header.isCompatible) ?? true,
               position + header.frameSize <= end {
                let next = position + header.frameSize
                let confirmed = next + 4 > end || MP3Header(data, at: next).map(header.isCompatible) == true
                if confirmed || reference != nil {
                    frames.append(MP3Frame(offset: position, header: header))
                    reference = reference ?? header
                    position = next
                    continue
                }
            }
            position += 1
        }
        guard let first = frames.first else { throw MP3Error.notMP3 }

        // The first frame may be a Xing/Info (or VBRI) header rather than audio.
        let tagStart = first.offset + first.header.overhead
        let marker = data.count >= tagStart + 4 ? String(decoding: data[data.startIndex + tagStart..<data.startIndex + tagStart + 4], as: UTF8.self) : ""
        var delay = 0
        var padding = 0
        var lameTag: Data?
        if marker == "Xing" || marker == "Info" {
            let flags = Self.uint32(data, tagStart + 4)
            var cursor = tagStart + 8
            for (bit, size) in [(1, 4), (2, 4), (4, 100), (8, 4)] where flags & UInt32(bit) != 0 { cursor += size }
            // The LAME extension: encoder string, then delay/padding at +21.
            // Only trusted when its CRC checks out, as Apple's decoder does.
            let crcOffset = cursor + 34
            if crcOffset + 2 <= first.offset + first.size,
               Self.crc16(data[data.startIndex + first.offset..<data.startIndex + crcOffset]) == UInt16(Self.uint32(data, crcOffset - 2) & 0xFFFF) {
                let b = data.startIndex + cursor + 21
                delay = Int(data[b]) << 4 | Int(data[b + 1]) >> 4
                padding = Int(data[b + 1] & 0x0F) << 8 | Int(data[b + 2])
                lameTag = data[data.startIndex + cursor..<data.startIndex + crcOffset]
            }
            frames.removeFirst()
        } else if marker == "VBRI" || String(decoding: data[data.startIndex + first.offset + 36..<data.startIndex + min(first.offset + 40, data.count)], as: UTF8.self) == "VBRI" {
            frames.removeFirst()
        }
        guard !frames.isEmpty else { throw MP3Error.notMP3 }
        self.frames = frames
        self.delay = delay
        self.padding = padding
        self.lameTag = lameTag
    }

    // MARK: - Cutting

    /// A new MP3 holding exactly the samples in `range`, built from the
    /// original frames. Two priming frames go in front so the decoder's
    /// bit reservoir and filter bank are primed, and the new gapless
    /// header tells it to skip them, so the result decodes to the same
    /// samples as the source.
    func cut(_ range: Range<Int64>, keepTags: Bool = true) throws -> Data {
        let spf = samplesPerFrame
        let start = Int(range.lowerBound) + delay
        let length = Int(range.upperBound - range.lowerBound)
        let startFrame = start / spf

        var body = Data()
        var audioFrames: [MP3Header] = []
        var firstFrame = startFrame
        var newDelay = start % spf
        if startFrame >= 2 {
            // Frame n-1 must decode correctly (it feeds frame n's overlap),
            // so it needs its reservoir: a silent frame carrying those bytes
            // stands in for frame n-2.
            let previous = frames[startFrame - 1]
            let current = frames[startFrame]
            let needed = max(mainDataBegin(previous), mainDataBegin(current) - previous.mainDataSize, 0)
            body.append(try reservoirFrame(carrying: needed, before: startFrame - 1))
            audioFrames.append(MP3Header(body, at: 0)!)
            firstFrame = startFrame - 1
            newDelay += 2 * spf
        } else {
            firstFrame = 0
            newDelay = start
        }
        // Two frames past the end cover the decoder's look-ahead.
        let endFrame = min((start + length + spf - 1) / spf + 2, frames.count)
        for frame in frames[firstFrame..<endFrame] {
            body.append(data[data.startIndex + frame.offset..<data.startIndex + frame.offset + frame.size])
            audioFrames.append(frame.header)
        }
        let newPadding = audioFrames.count * spf - newDelay - length
        guard newDelay <= 4095, (0...4095).contains(newPadding) else {
            throw MP3Error.unsupported("the cut needs more encoder delay than the MP3 header can describe")
        }

        let info = infoFrame(for: audioFrames, bodyBytes: body.count, delay: newDelay, padding: newPadding, body: body)
        var output = Data()
        if keepTags, let id3v2 { output.append(data[data.startIndex + id3v2.lowerBound..<data.startIndex + id3v2.upperBound]) }
        output.append(info)
        output.append(body)
        if keepTags, let id3v1 { output.append(data[data.startIndex + id3v1.lowerBound..<data.startIndex + id3v1.upperBound]) }
        return output
    }

    /// Bytes of the previous frames' main data this frame starts in.
    private func mainDataBegin(_ frame: MP3Frame) -> Int {
        let b = data.startIndex + frame.offset + (frame.header.hasCRC ? 6 : 4)
        return frame.header.version == .mpeg1 ? Int(data[b]) << 1 | Int(data[b + 1]) >> 7 : Int(data[b])
    }

    /// A frame that decodes to silence (all side information zero) whose
    /// main data ends with the `count` bytes of main data that come before
    /// frame `index` in the source.
    private func reservoirFrame(carrying count: Int, before index: Int) throws -> Data {
        let template = frames[index].header
        guard let rate = (1...14).first(where: {
            let header = template.with(bitRateIndex: $0)
            return header.frameSize - header.overhead >= count
        }) else {
            throw MP3Error.unsupported("the bit reservoir is larger than any frame")
        }
        let header = template.with(bitRateIndex: rate)
        var frame = Data(header.bytes)
        frame.append(Data(count: header.frameSize - 4))
        // Walk back through earlier frames' main data to collect the bytes.
        var collected = Data()
        var cursor = index - 1
        while collected.count < count, cursor >= 0 {
            let previous = frames[cursor]
            let main = data[data.startIndex + previous.offset + previous.header.overhead..<data.startIndex + previous.offset + previous.size]
            collected = main + collected
            cursor -= 1
        }
        let bytes = collected.suffix(count)
        frame.replaceSubrange(frame.count - bytes.count..<frame.count, with: bytes)
        return frame
    }

    /// A Xing/Info frame with a LAME extension carrying the gapless delay
    /// and padding, the frame count, byte count and seek table.
    private func infoFrame(for headers: [MP3Header], bodyBytes: Int, delay: Int, padding: Int, body: Data) -> Data {
        let template = headers[headers.count > 1 ? 1 : 0]
        let isVBR = Set(headers.map(\.bitRateIndex)).count > 1
        let side = template.with(bitRateIndex: 1).sideInfoSize
        let needed = 4 + side + 120 + 36
        let rate = (1...14).first { template.with(bitRateIndex: $0).frameSize >= needed } ?? 14
        let header = template.with(bitRateIndex: rate)
        var frame = Data(header.bytes)
        frame.append(Data(count: header.frameSize - 4))
        let base = 4 + side
        frame.replaceSubrange(base..<base + 4, with: Data((isVBR ? "Xing" : "Info").utf8))
        Self.put(UInt32(0x0F), into: &frame, at: base + 4)  // frames, bytes, TOC, quality
        Self.put(UInt32(headers.count), into: &frame, at: base + 8)
        let totalBytes = bodyBytes + frame.count
        Self.put(UInt32(totalBytes), into: &frame, at: base + 12)
        // Seek table: where each percent of the duration starts, in 1/256ths
        // of the file.
        var offsets: [Int] = []
        var running = frame.count
        var index = 0
        while offsets.count < 100 {
            let target = headers.count * offsets.count / 100
            while index < target { running += headers[index].frameSize; index += 1 }
            offsets.append(running)
        }
        for (percent, offset) in offsets.enumerated() {
            frame[base + 16 + percent] = UInt8(min(255, offset * 256 / max(totalBytes, 1)))
        }
        Self.put(UInt32(0), into: &frame, at: base + 116)  // quality: unknown

        let lame = base + 120
        var tag = lameTag.map { Data($0) } ?? Data(count: 34)
        if lameTag == nil { tag.replaceSubrange(0..<9, with: Data("DEX      ".utf8)) }
        // ReplayGain described the whole track, not this part of it.
        tag.replaceSubrange(11..<19, with: Data(count: 8))
        tag[21] = UInt8(delay >> 4)
        tag[22] = UInt8((delay & 0x0F) << 4 | padding >> 8)
        tag[23] = UInt8(padding & 0xFF)
        // Music length and CRC cover the audio after this frame.
        let musicLength = UInt32(totalBytes)
        tag.replaceSubrange(28..<32, with: Data([UInt8(musicLength >> 24), UInt8(musicLength >> 16 & 0xFF), UInt8(musicLength >> 8 & 0xFF), UInt8(musicLength & 0xFF)]))
        let musicCRC = Self.crc16(body)
        tag[32] = UInt8(musicCRC >> 8)
        tag[33] = UInt8(musicCRC & 0xFF)
        frame.replaceSubrange(lame..<lame + 34, with: tag)
        let crc = Self.crc16(frame[0..<lame + 34])
        frame[lame + 34] = UInt8(crc >> 8)
        frame[lame + 35] = UInt8(crc & 0xFF)
        return frame
    }

    // MARK: - Bytes

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        let b = data.startIndex + offset
        return UInt32(data[b]) << 24 | UInt32(data[b + 1]) << 16 | UInt32(data[b + 2]) << 8 | UInt32(data[b + 3])
    }

    private static func put(_ value: UInt32, into data: inout Data, at offset: Int) {
        data.replaceSubrange(offset..<offset + 4, with: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    /// CRC-16 (polynomial 0x8005, reflected), as used by the LAME header.
    static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }
}
