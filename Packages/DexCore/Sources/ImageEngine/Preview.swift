import CoreGraphics
import Foundation
import ImageIO
import JobSystem
import MediaModel

/// Wraps a CGImage for crossing actor boundaries. CGImage is immutable.
public struct PreviewImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let isHDR: Bool
}

extension ImageEngine {
    /// An upright, down-sampled image for display, decoded as HDR when the
    /// file has a gain map so HDR screens show real highlights. Never decodes
    /// the full-resolution image.
    public static func preview(url: URL, maxPixelSize: Int = 2048) async throws -> PreviewImage {
        try await MediaWork.run { token in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw InspectError.notAnImage(url.lastPathComponent)
            }
            try token.check()
            let isHDR = [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap].contains {
                CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil
            }
            var options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if isHDR {
                options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR
            }
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw InspectError.corrupt(url.lastPathComponent)
            }
            return PreviewImage(cgImage: image, isHDR: isHDR)
        }
    }

    /// The full-resolution image with an EXIF orientation applied, for
    /// pixel-accurate views such as the crop loupe. Images above
    /// `maxMegapixels` fall back to a down-sampled decode.
    public static func displayImage(url: URL, orientation: Int, maxMegapixels: Int = 50) async throws -> PreviewImage {
        try await MediaWork.run { token in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            else {
                throw InspectError.notAnImage(url.lastPathComponent)
            }
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            var image: CGImage
            if width * height > maxMegapixels * 1_000_000 {
                let options = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 8192,
                ] as CFDictionary
                guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                    throw InspectError.corrupt(url.lastPathComponent)
                }
                image = thumbnail
            } else {
                image = try decodedFrame(source, index: 0, name: url.lastPathComponent)
            }
            try token.check()
            image = try PixelOps.orient(image, orientation)
            return PreviewImage(cgImage: image, isHDR: false)
        }
    }

    /// `inspect` off the calling actor, for UI code.
    public static func inspectAsync(url: URL) async throws -> MediaInfo {
        try await MediaWork.run { _ in try inspect(url: url) }
    }
}
