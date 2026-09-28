import Foundation
import ImageIO
import MediaModel

public enum InspectError: Error, Equatable, CustomStringConvertible {
    case fileNotFound(String)
    case notAFile(String)
    case emptyFile(String)
    case notAnImage(String)
    case corrupt(String)

    public var description: String {
        switch self {
        case .fileNotFound(let name): "“\(name)” could not be found."
        case .notAFile(let name): "“\(name)” is a folder, not a file."
        case .emptyFile(let name): "“\(name)” is empty (0 bytes)."
        case .notAnImage(let name): "“\(name)” is not an image format DEX can read."
        case .corrupt(let name): "“\(name)” looks damaged or incomplete and could not be decoded."
        }
    }
}

public enum ImageEngine {
    /// Reads format, geometry, colour and metadata facts from an image file
    /// without decoding it at full resolution.
    public static func inspect(url: URL) throws -> MediaInfo {
        let name = url.lastPathComponent
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        } catch {
            throw InspectError.fileNotFound(name)
        }
        if values.isDirectory == true { throw InspectError.notAFile(name) }
        let fileSize = Int64(values.fileSize ?? 0)
        if fileSize == 0 { throw InspectError.emptyFile(name) }

        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let typeIdentifier = CGImageSourceGetType(source) as String?
        else {
            throw InspectError.notAnImage(name)
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else {
            throw InspectError.corrupt(name)
        }
        try verifyDecodable(source, name: name)

        return MediaInfo(
            fileName: name,
            fileSize: fileSize,
            typeIdentifier: typeIdentifier,
            format: ImageFormat(typeIdentifier: typeIdentifier),
            pixelWidth: width,
            pixelHeight: height,
            orientation: properties[kCGImagePropertyOrientation] as? Int ?? 1,
            bitsPerComponent: properties[kCGImagePropertyDepth] as? Int,
            colorModel: properties[kCGImagePropertyColorModel] as? String,
            colorProfile: properties[kCGImagePropertyProfileName] as? String,
            hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false,
            hasHDRGainMap: hasGainMap(source),
            frameCount: frameCount,
            hasGPS: properties[kCGImagePropertyGPSDictionary] != nil
        )
    }

    /// Type identifiers ImageIO can decode on this system.
    public static func readableTypeIdentifiers() -> [String] {
        (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).sorted()
    }

    /// Type identifiers ImageIO can encode on this system. Varies by macOS
    /// version (e.g. AVIF), so it is queried rather than hard-coded.
    public static func writableTypeIdentifiers() -> [String] {
        (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).sorted()
    }

    /// Whether ImageIO itself can encode this format on this system.
    public static func canWriteNatively(_ format: ImageFormat) -> Bool {
        writableTypeIdentifiers().contains(format.typeIdentifier)
    }

    // MARK: - Private

    /// Headers can parse while the pixel data is missing, so decode a tiny
    /// thumbnail to prove the image data is actually usable.
    private static func verifyDecodable(_ source: CGImageSource, name: String) throws {
        if CGImageSourceGetStatusAtIndex(source, 0) != .statusComplete {
            throw InspectError.corrupt(name)
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceShouldCache: false,
        ] as CFDictionary
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, options) != nil else {
            throw InspectError.corrupt(name)
        }
    }

    private static func hasGainMap(_ source: CGImageSource) -> Bool {
        [kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeHDRGainMap].contains { type in
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) != nil
        }
    }
}
