import Foundation

/// Metadata removal at the JPEG marker level: the compressed image data is
/// copied byte for byte, so the result is exactly the original minus its
/// metadata. Re-packing (jpegtran) can be less efficient than whatever made
/// an already-optimised file.
enum JPEGMarkers {
    enum StripError: Error { case notJPEG, truncated }

    /// Keeps what decoding needs (tables, frame, scans), JFIF, Adobe APP14
    /// (colour transform) and ICC profiles; drops EXIF/XMP (APP1), MPF and
    /// other APP2, APP3–APP13, APP15, comments, and anything after the end
    /// of the image (e.g. an HDR gain map it pointed to). Writes a minimal
    /// orientation-only EXIF block when orientation isn't 1.
    static func strippingMetadata(_ data: Data, orientation: Int) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw StripError.notJPEG }
        var output: [UInt8] = [0xFF, 0xD8]
        var wroteOrientation = orientation <= 1 || orientation > 8
        var index = 2

        while index + 3 < bytes.count {
            guard bytes[index] == 0xFF else { throw StripError.truncated }
            var markerIndex = index + 1
            while markerIndex < bytes.count && bytes[markerIndex] == 0xFF { markerIndex += 1 }  // fill bytes
            guard markerIndex + 2 < bytes.count else { throw StripError.truncated }
            let marker = bytes[markerIndex]
            let length = Int(bytes[markerIndex + 1]) << 8 | Int(bytes[markerIndex + 2])
            let segmentEnd = markerIndex + 1 + length
            guard length >= 2, segmentEnd <= bytes.count else { throw StripError.truncated }
            let payload = bytes[(markerIndex + 3)..<segmentEnd]

            if !wroteOrientation && marker != 0xE0 {
                output += orientationSegment(orientation)
                wroteOrientation = true
            }

            if marker == 0xDA {
                // Start of scan: copy everything through the end-of-image
                // marker verbatim. In entropy-coded data FF is always
                // followed by 00 or a restart marker, so FF D9 is the end.
                var end = markerIndex + 1
                while end + 1 < bytes.count && !(bytes[end] == 0xFF && bytes[end + 1] == 0xD9) { end += 1 }
                guard end + 1 < bytes.count else { throw StripError.truncated }
                output += bytes[index...(end + 1)]
                return Data(output)
            }
            if keeps(marker, payload) {
                output += [0xFF, marker] + bytes[(markerIndex + 1)..<segmentEnd]
            }
            index = segmentEnd
        }
        throw StripError.truncated
    }

    private static func keeps(_ marker: UInt8, _ payload: ArraySlice<UInt8>) -> Bool {
        switch marker {
        case 0xE0, 0xEE: true  // JFIF, Adobe (needed for CMYK/YCCK)
        case 0xE2: payload.starts(with: Array("ICC_PROFILE".utf8) + [0])
        case 0xE1, 0xE3...0xED, 0xEF, 0xFE: false  // EXIF/XMP, vendor APPs, comments
        default: true  // DQT, SOF, DHT, DRI, …
        }
    }

    /// "Exif\0\0", big-endian TIFF header, one IFD entry (Orientation).
    private static func orientationSegment(_ orientation: Int) -> [UInt8] {
        let body: [UInt8] = [
            0x45, 0x78, 0x69, 0x66, 0, 0,
            0x4D, 0x4D, 0, 42, 0, 0, 0, 8,
            0, 1,
            0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, UInt8(orientation), 0, 0,
            0, 0, 0, 0,
        ]
        let length = body.count + 2
        return [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + body
    }
}
