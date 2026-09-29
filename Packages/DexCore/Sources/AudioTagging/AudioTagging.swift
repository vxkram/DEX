import AVFoundation
import Foundation
import MediaModel

public enum AudioTagError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .unreadable(let detail): "The tags couldn't be read: \(detail)."
        case .writeFailed(let detail): "The tags couldn't be written: \(detail)."
        }
    }
}

/// Reads and writes title, artist, album and cover art without touching
/// the audio data: ID3v2 for MP3, Vorbis comments and a PICTURE block for
/// FLAC, and iTunes metadata (an AVFoundation passthrough) for M4A.
public enum AudioTagging {
    // MARK: - Reading

    public static func tags(of url: URL) async -> AudioTags {
        if url.pathExtension.lowercased() == "flac", let data = try? Data(contentsOf: url, options: .alwaysMapped),
           let tags = FLACTags.read(data) {
            return tags
        }
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return AudioTags() }
        var tags = AudioTags()
        for item in items {
            switch item.commonKey {
            case .commonKeyTitle?: tags.title = try? await item.load(.stringValue)
            case .commonKeyArtist?: tags.artist = try? await item.load(.stringValue)
            case .commonKeyAlbumName?: tags.album = try? await item.load(.stringValue)
            case .commonKeyArtwork?:
                if tags.artwork == nil, let data = try? await item.load(.dataValue), !data.isEmpty {
                    tags.artwork = Artwork(data: data)
                }
            default: break
            }
        }
        return tags
    }

    // MARK: - Writing

    /// Rewrites the file's tags in place (via a temporary file for M4A).
    public static func write(_ tags: AudioTags, to url: URL, format: AudioFormat) async throws {
        switch format {
        case .mp3:
            let data = try Data(contentsOf: url)
            try ID3.retag(data, with: tags).write(to: url, options: .atomic)
        case .flac:
            let data = try Data(contentsOf: url)
            guard let tagged = FLACTags.write(tags, into: data) else { throw AudioTagError.writeFailed("not a FLAC stream") }
            try tagged.write(to: url, options: .atomic)
        case .aac, .alac:
            let temporary = url.deletingLastPathComponent().appendingPathComponent("tagging-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await passthrough(url, range: nil, metadata: metadataItems(tags), to: temporary)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        case .wav, .aiff:
            break
        }
    }

    /// M4A passthrough (no re-encoding), optionally trimmed to `range` and
    /// with the given metadata instead of the source's.
    public static func passthrough(_ source: URL, range: CMTimeRange?, metadata: [AVMetadataItem]?, to output: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw AudioTagError.writeFailed("this file can't be copied without re-encoding")
        }
        if let range { session.timeRange = range }
        if let metadata { session.metadata = metadata }
        do {
            try await session.export(to: output, as: .m4a)
        } catch {
            throw AudioTagError.writeFailed(error.localizedDescription)
        }
    }

    public static func metadataItems(_ tags: AudioTags) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func add(_ identifier: AVMetadataIdentifier, _ value: (NSCopying & NSObjectProtocol)?, dataType: String? = nil) {
            guard let value else { return }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            if let dataType { item.dataType = dataType }
            items.append(item)
        }
        add(.iTunesMetadataSongName, tags.title.flatMap { $0.isEmpty ? nil : $0 as NSString })
        add(.iTunesMetadataArtist, tags.artist.flatMap { $0.isEmpty ? nil : $0 as NSString })
        add(.iTunesMetadataAlbum, tags.album.flatMap { $0.isEmpty ? nil : $0 as NSString })
        if let artwork = tags.artwork {
            add(.iTunesMetadataCoverArt, artwork.data as NSData,
                dataType: (artwork.isPNG ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG) as String)
        }
        return items
    }
}

// MARK: - ID3v2 (MP3)

enum ID3 {
    /// The file with its leading ID3v2 tag replaced: title, artist, album
    /// and front cover from `tags`, every other frame of the old tag kept.
    static func retag(_ file: Data, with tags: AudioTags) -> Data {
        var version: UInt8 = 3
        var kept: [(id: String, body: Data)] = []
        var audio = file
        if let existing = parse(file) {
            version = existing.version
            kept = existing.frames.filter { !["TIT2", "TPE1", "TALB", "APIC"].contains($0.id) }
            audio = file.subdata(in: existing.size..<file.count)
        }
        var frames = kept
        func text(_ id: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            // UTF-16 with a byte-order mark: valid in ID3v2.3 and 2.4.
            var body = Data([1, 0xFF, 0xFE])
            body.append(value.data(using: .utf16LittleEndian) ?? Data())
            frames.append((id, body))
        }
        text("TIT2", tags.title)
        text("TPE1", tags.artist)
        text("TALB", tags.album)
        if let artwork = tags.artwork {
            var body = Data([0])
            body.append(Data(artwork.mimeType.utf8))
            body.append(contentsOf: [0, 3, 0])  // end of MIME, front cover, empty description
            body.append(artwork.data)
            frames.append(("APIC", body))
        }
        guard !frames.isEmpty else { return audio }

        var content = Data()
        for frame in frames {
            content.append(Data(frame.id.utf8))
            content.append(version == 4 ? syncsafe(frame.body.count) : bigEndian(frame.body.count))
            content.append(contentsOf: [0, 0])
            content.append(frame.body)
        }
        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [version, 0, 0])
        tag.append(syncsafe(content.count))
        return tag + content + audio
    }

    struct Tag {
        let version: UInt8
        let size: Int
        let frames: [(id: String, body: Data)]
    }

    /// A v2.3/v2.4 tag's frames. Tags using unsynchronisation, extended
    /// headers or v2.2 are replaced rather than merged.
    static func parse(_ data: Data) -> Tag? {
        guard data.count >= 10, data.prefix(3) == Data("ID3".utf8) else { return nil }
        let b = data.startIndex
        let version = data[b + 3]
        let flags = data[b + 5]
        let size = 10 + readSyncsafe(data, 6) + (flags & 0x10 != 0 ? 10 : 0)
        guard size <= data.count else { return nil }
        guard version == 3 || version == 4, flags & 0xC0 == 0 else { return Tag(version: 3, size: size, frames: []) }
        var frames: [(String, Data)] = []
        var cursor = 10
        while cursor + 10 <= size - (flags & 0x10 != 0 ? 10 : 0) {
            let id = String(decoding: data[b + cursor..<b + cursor + 4], as: UTF8.self)
            guard id.allSatisfy({ $0.isUppercase || $0.isNumber }), id != "\0\0\0\0" else { break }
            let length = version == 4 ? readSyncsafe(data, cursor + 4) : readBigEndian(data, cursor + 4)
            guard length > 0, cursor + 10 + length <= size else { break }
            frames.append((id, data.subdata(in: b + cursor + 10..<b + cursor + 10 + length)))
            cursor += 10 + length
        }
        return Tag(version: version, size: size, frames: frames)
    }

    static func syncsafe(_ value: Int) -> Data {
        Data([UInt8(value >> 21 & 0x7F), UInt8(value >> 14 & 0x7F), UInt8(value >> 7 & 0x7F), UInt8(value & 0x7F)])
    }

    static func bigEndian(_ value: Int) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    static func readSyncsafe(_ data: Data, _ offset: Int) -> Int {
        let b = data.startIndex + offset
        return Int(data[b]) << 21 | Int(data[b + 1]) << 14 | Int(data[b + 2]) << 7 | Int(data[b + 3])
    }

    static func readBigEndian(_ data: Data, _ offset: Int) -> Int {
        let b = data.startIndex + offset
        return Int(data[b]) << 24 | Int(data[b + 1]) << 16 | Int(data[b + 2]) << 8 | Int(data[b + 3])
    }
}

// MARK: - FLAC metadata blocks

enum FLACTags {
    struct Block {
        var type: UInt8
        var body: Data
    }

    static func blocks(_ data: Data) -> (blocks: [Block], audioStart: Int)? {
        guard data.count > 8, data.prefix(4) == Data("fLaC".utf8) else { return nil }
        var blocks: [Block] = []
        var cursor = 4
        while cursor + 4 <= data.count {
            let b = data.startIndex + cursor
            let header = data[b]
            let length = Int(data[b + 1]) << 16 | Int(data[b + 2]) << 8 | Int(data[b + 3])
            guard cursor + 4 + length <= data.count else { return nil }
            blocks.append(Block(type: header & 0x7F, body: data.subdata(in: b + 4..<b + 4 + length)))
            cursor += 4 + length
            if header & 0x80 != 0 { return (blocks, cursor) }
        }
        return nil
    }

    static func read(_ data: Data) -> AudioTags? {
        guard let (blocks, _) = blocks(data) else { return nil }
        var tags = AudioTags()
        for block in blocks {
            if block.type == 4 {
                for (key, value) in comments(block.body) {
                    switch key.uppercased() {
                    case "TITLE": tags.title = value
                    case "ARTIST": tags.artist = value
                    case "ALBUM": tags.album = value
                    default: break
                    }
                }
            } else if block.type == 6, tags.artwork == nil, let picture = pictureData(block.body) {
                tags.artwork = Artwork(data: picture)
            }
        }
        return tags
    }

    /// The stream with its Vorbis comment and PICTURE blocks replaced
    /// (other comments kept) and padding dropped. The audio is untouched.
    static func write(_ tags: AudioTags, into data: Data) -> Data? {
        guard let (blocks, audioStart) = blocks(data), blocks.first?.type == 0 else { return nil }
        var vendor = "DEX"
        var others: [(String, String)] = []
        for block in blocks where block.type == 4 {
            vendor = commentVendor(block.body) ?? vendor
            others = comments(block.body).filter { !["TITLE", "ARTIST", "ALBUM"].contains($0.0.uppercased()) }
        }
        var entries = others
        if let title = tags.title, !title.isEmpty { entries.append(("TITLE", title)) }
        if let artist = tags.artist, !artist.isEmpty { entries.append(("ARTIST", artist)) }
        if let album = tags.album, !album.isEmpty { entries.append(("ALBUM", album)) }

        var output = blocks.filter { ![1, 4, 6].contains($0.type) }
        var comment = littleEndian(vendor.utf8.count) + Data(vendor.utf8) + littleEndian(entries.count)
        for (key, value) in entries {
            let entry = Data("\(key)=\(value)".utf8)
            comment += littleEndian(entry.count) + entry
        }
        output.append(Block(type: 4, body: comment))
        if let artwork = tags.artwork {
            var picture = bigEndian(3) + bigEndian(artwork.mimeType.utf8.count) + Data(artwork.mimeType.utf8)
            picture += bigEndian(0)  // no description
            picture += bigEndian(0) + bigEndian(0) + bigEndian(0) + bigEndian(0)  // size and colours: unknown
            picture += bigEndian(artwork.data.count) + artwork.data
            output.append(Block(type: 6, body: picture))
        }

        var result = Data("fLaC".utf8)
        for (index, block) in output.enumerated() {
            let last: UInt8 = index == output.count - 1 ? 0x80 : 0
            let length = block.body.count
            result.append(contentsOf: [block.type | last, UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
            result.append(block.body)
        }
        result.append(data.subdata(in: data.startIndex + audioStart..<data.endIndex))
        return result
    }

    private static func comments(_ body: Data) -> [(String, String)] {
        var cursor = 0
        func uint32() -> Int? {
            guard cursor + 4 <= body.count else { return nil }
            let b = body.startIndex + cursor
            cursor += 4
            return Int(body[b]) | Int(body[b + 1]) << 8 | Int(body[b + 2]) << 16 | Int(body[b + 3]) << 24
        }
        guard let vendorLength = uint32() else { return [] }
        cursor += vendorLength
        guard let count = uint32() else { return [] }
        var result: [(String, String)] = []
        for _ in 0..<count {
            guard let length = uint32(), cursor + length <= body.count else { break }
            let text = String(decoding: body[body.startIndex + cursor..<body.startIndex + cursor + length], as: UTF8.self)
            cursor += length
            if let equals = text.firstIndex(of: "=") {
                result.append((String(text[..<equals]), String(text[text.index(after: equals)...])))
            }
        }
        return result
    }

    private static func commentVendor(_ body: Data) -> String? {
        guard body.count >= 4 else { return nil }
        let length = Int(body[body.startIndex]) | Int(body[body.startIndex + 1]) << 8
            | Int(body[body.startIndex + 2]) << 16 | Int(body[body.startIndex + 3]) << 24
        guard 4 + length <= body.count else { return nil }
        return String(decoding: body[body.startIndex + 4..<body.startIndex + 4 + length], as: UTF8.self)
    }

    private static func pictureData(_ body: Data) -> Data? {
        var cursor = 4
        func uint32() -> Int? {
            guard cursor + 4 <= body.count else { return nil }
            let value = ID3.readBigEndian(body, cursor)
            cursor += 4
            return value
        }
        guard let mimeLength = uint32() else { return nil }
        cursor += mimeLength
        guard let descriptionLength = uint32() else { return nil }
        cursor += descriptionLength + 16
        guard let length = uint32(), cursor + length <= body.count else { return nil }
        return body.subdata(in: body.startIndex + cursor..<body.startIndex + cursor + length)
    }

    private static func littleEndian(_ value: Int) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)])
    }

    private static func bigEndian(_ value: Int) -> Data { ID3.bigEndian(value) }
}
