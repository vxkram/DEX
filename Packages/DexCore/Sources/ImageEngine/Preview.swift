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

    /// `inspect` off the calling actor, for UI code.
    public static func inspectAsync(url: URL) async throws -> MediaInfo {
        try await MediaWork.run { _ in try inspect(url: url) }
    }
}
