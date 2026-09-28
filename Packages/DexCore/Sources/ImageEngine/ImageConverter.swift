import Foundation
import ImageIO
import JobSystem
import MediaModel

public enum ConvertError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case encodeFailed(ImageFormat, reason: String? = nil)
    /// The written file did not match the plan. Nothing was saved.
    case verificationFailed(String)

    public var description: String {
        switch self {
        case .unreadable(let name): "“\(name)” could not be read."
        case .encodeFailed(let format, let reason):
            "Writing the \(format.displayName) file failed" + (reason.map { ": \($0)" } ?? ".")
        case .verificationFailed(let reason): "The result failed a safety check (\(reason)), so nothing was saved."
        }
    }
}

extension ImageEngine {
    /// Formats DEX can currently write.
    public static func writableFormats() -> Set<ImageFormat> {
        Set(ImageFormat.allCases.filter(canWrite))
    }

    /// Plans a conversion for a file on disk.
    public static func plan(_ source: URL, _ request: ConvertRequest) throws -> (MediaInfo, ConversionPlan) {
        let info = try inspect(url: source)
        return (info, try Planner.plan(info, request, writable: writableFormats()))
    }

    /// Executes a plan on the media work queue. The output is verified
    /// against the plan before it is moved into place; a mismatch, error or
    /// cancellation leaves nothing behind.
    public static func convert(
        _ source: URL,
        plan: ConversionPlan,
        to destination: URL,
        overwrite: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try await MediaWork.run { token in
            try SafeOutput.write(to: destination, source: source, overwrite: overwrite, cancellation: token) { temporary in
                switch plan.strategy {
                case .copyFile:
                    try FileManager.default.copyItem(at: source, to: temporary)
                case .rewriteMetadata:
                    try rewriteMetadata(source, plan: plan, to: temporary)
                case .reencode:
                    try reencode(source, plan: plan, to: temporary, token: token, progress: progress)
                }
                try verify(temporary, against: plan)
                progress?(1)
            }
        }
    }

    // MARK: - Strategies

    private static func rewriteMetadata(_ url: URL, plan: ConversionPlan, to temporary: URL) throws {
        let source = try openSource(url)
        let target = plan.request.target
        guard let destination = CGImageDestinationCreateWithURL(
            temporary as CFURL, target.typeIdentifier as CFString, CGImageSourceGetCount(source), nil
        ) else {
            throw ConvertError.encodeFailed(target)
        }
        var options: [CFString: Any] = [
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: plan.request.metadata != .keepAll,
        ]
        switch plan.request.metadata {
        case .keepAll:
            break
        case .removeLocation:
            // `kCGImageMetadataShouldExcludeGPS` alone only works for JPEG, so
            // GPS tags are removed explicitly (verified on macOS 27).
            if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
                options[kCGImageDestinationMetadata] = removingLocation(from: metadata)
            }
        case .removeAll:
            // `kCGImageDestinationOrientation` can't be combined with
            // `kCGImageDestinationMetadata`, so orientation goes in as a tag.
            let metadata = CGImageMetadataCreateMutable()
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation,
                orientation(of: source) as CFNumber
            )
            options[kCGImageDestinationMetadata] = metadata
        }
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            let reason = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String }
            throw ConvertError.encodeFailed(target, reason: reason)
        }
    }

    private static func reencode(
        _ url: URL,
        plan: ConversionPlan,
        to temporary: URL,
        token: CancellationToken,
        progress: (@Sendable (Double) -> Void)?
    ) throws {
        let source = try openSource(url)
        let target = plan.request.target
        let frames = plan.expectedFrameCount
        guard let destination = CGImageDestinationCreateWithURL(
            temporary as CFURL, target.typeIdentifier as CFString, frames, nil
        ) else {
            throw ConvertError.encodeFailed(target)
        }
        if frames > 1, let container = CGImageSourceCopyProperties(source, nil) {
            // Carries animation-wide settings such as the GIF loop count.
            CGImageDestinationSetProperties(destination, container)
        }

        for index in 0..<frames {
            try token.check()
            var properties = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
            if let quality = plan.lossyQuality {
                properties[kCGImageDestinationLossyCompressionQuality] = quality
            }
            switch plan.request.metadata {
            case .keepAll:
                break
            case .removeLocation:
                properties[kCGImagePropertyGPSDictionary] = kCFNull
            case .removeAll:
                // Only what's needed to display the frames correctly.
                properties = properties.filter { key, _ in
                    [kCGImagePropertyOrientation, kCGImagePropertyGIFDictionary,
                     kCGImageDestinationLossyCompressionQuality].contains(key)
                }
            }
            if plan.appliesOrientation {
                properties[kCGImagePropertyOrientation] = 1
                let image = try uprightImage(source, index: index, name: url.lastPathComponent)
                CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            } else if plan.request.metadata == .removeAll {
                guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                    throw ConvertError.unreadable(url.lastPathComponent)
                }
                CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            } else {
                CGImageDestinationAddImageFromSource(destination, source, index, properties as CFDictionary)
            }
            progress?(Double(index + 1) / Double(frames) * 0.95)
        }
        try token.check()
        guard CGImageDestinationFinalize(destination) else {
            throw ConvertError.encodeFailed(target)
        }
    }

    // MARK: - Verification

    /// Checks the promises the plan made before anything reaches the user.
    private static func verify(_ output: URL, against plan: ConversionPlan) throws {
        let info: MediaInfo
        do {
            info = try inspect(url: output)
        } catch {
            throw ConvertError.verificationFailed("output is not readable")
        }
        if info.format != plan.request.target {
            throw ConvertError.verificationFailed("wrong format \(info.typeIdentifier)")
        }
        if info.pixelWidth != plan.expectedWidth || info.pixelHeight != plan.expectedHeight {
            throw ConvertError.verificationFailed(
                "size changed to \(info.pixelWidth)×\(info.pixelHeight), expected \(plan.expectedWidth)×\(plan.expectedHeight)"
            )
        }
        if info.frameCount != plan.expectedFrameCount {
            throw ConvertError.verificationFailed("\(info.frameCount) frames, expected \(plan.expectedFrameCount)")
        }
        if plan.request.metadata != .keepAll && info.hasGPS {
            throw ConvertError.verificationFailed("location data is still present")
        }
    }

    // MARK: - Helpers

    private static func openSource(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ConvertError.unreadable(url.lastPathComponent)
        }
        return source
    }

    /// Full-resolution frame with its EXIF orientation applied to the pixels.
    /// A thumbnail request at the image's own size is an exact transform.
    private static func uprightImage(_ source: CGImageSource, index: Int, name: String) throws -> CGImage {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options) else {
            throw ConvertError.unreadable(name)
        }
        return image
    }

    private static func orientation(of source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return properties?[kCGImagePropertyOrientation] as? Int ?? 1
    }

    private static func removingLocation(from metadata: CGImageMetadata) -> CGMutableImageMetadata {
        let copy = CGImageMetadataCreateMutableCopy(metadata) ?? CGImageMetadataCreateMutable()
        var gpsPaths: [CFString] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, _ in
            if (path as String).hasPrefix("exif:GPS") { gpsPaths.append(path) }
            return true
        }
        for path in gpsPaths {
            CGImageMetadataRemoveTagWithPath(copy, nil, path)
        }
        return copy
    }
}
