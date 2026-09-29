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
    /// Formats DEX can currently write: ImageIO's encoders plus WebP
    /// through the bundled libwebp.
    public static func writableFormats() -> Set<ImageFormat> {
        Set(ImageFormat.allCases.filter(canWriteNatively)).union([.webp])
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
                case .losslessJPEGCrop:
                    try losslessJPEGCrop(source, plan: plan, to: temporary)
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
        let changesOrientation = plan.outputOrientation != orientation(of: source)
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil).map {
            policyMetadata($0, plan.request.metadata, orientation: changesOrientation ? plan.outputOrientation : nil)
        }
        var input = source
        if changesOrientation {
            // HEIC keeps rotation in its container (irot/imir), which only
            // kCGImageDestinationOrientation updates, and that option can't
            // be combined with new metadata. So: orientation first, into
            // memory, then the metadata pass. Both passes are lossless.
            input = try reoriented(source, to: plan.outputOrientation, format: target)
        }
        try copyImageSource(input, into: destination, metadata: metadata, plan: plan)
    }

    private static func reoriented(_ source: CGImageSource, to orientation: Int, format: ImageFormat) throws -> CGImageSource {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, format.typeIdentifier as CFString, CGImageSourceGetCount(source), nil
        ) else {
            throw ConvertError.encodeFailed(format)
        }
        var error: Unmanaged<CFError>?
        let options = [kCGImageDestinationOrientation: orientation] as CFDictionary
        guard CGImageDestinationCopyImageSource(destination, source, options, &error),
              let result = CGImageSourceCreateWithData(data as CFData, nil)
        else {
            let reason = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String }
            throw ConvertError.encodeFailed(format, reason: reason)
        }
        return result
    }

    /// Crops the JPEG's compressed data (no decode), then writes the
    /// original metadata, filtered by the policy, around it with ImageIO.
    private static func losslessJPEGCrop(_ url: URL, plan: ConversionPlan, to temporary: URL) throws {
        guard let rect = plan.pixelCrop else { throw ConvertError.encodeFailed(.jpeg, reason: "no crop") }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let cropped = try JPEGLossless.crop(data, to: rect, progressive: JPEGLossless.info(of: data)?.progressive ?? false)
        let original = try openSource(url)
        guard let croppedSource = CGImageSourceCreateWithData(cropped as CFData, nil),
              let destination = CGImageDestinationCreateWithURL(temporary as CFURL, ImageFormat.jpeg.typeIdentifier as CFString, 1, nil)
        else {
            throw ConvertError.encodeFailed(.jpeg)
        }
        let metadata = CGImageSourceCopyMetadataAtIndex(original, 0, nil).map {
            policyMetadata($0, plan.request.metadata, orientation: plan.outputOrientation, droppingSize: true)
        } ?? orientationOnlyMetadata(plan.outputOrientation)
        try copyImageSource(croppedSource, into: destination, metadata: metadata, plan: plan)
    }

    private static func copyImageSource(
        _ source: CGImageSource, into destination: CGImageDestination, metadata: CGImageMetadata?, plan: ConversionPlan
    ) throws {
        var options: [CFString: Any] = [
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: plan.request.metadata != .keepAll,
        ]
        options[kCGImageDestinationMetadata] = metadata
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            let reason = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String }
            throw ConvertError.encodeFailed(plan.request.target, reason: reason)
        }
    }

    /// Source metadata filtered by the policy. `kCGImageMetadataShouldExcludeGPS`
    /// alone only works for JPEG, so GPS tags are removed explicitly. For
    /// "remove all" a copy is trimmed to orientation: fresh metadata drops
    /// Apple's HDR maker note, and empty metadata makes HEIC keep everything
    /// (both measured on macOS 27).
    private static func policyMetadata(
        _ metadata: CGImageMetadata, _ policy: MetadataPolicy, orientation: Int?, droppingSize: Bool = false
    ) -> CGMutableImageMetadata {
        let stale: Set<String> = droppingSize ? ["exif:PixelXDimension", "exif:PixelYDimension"] : []
        let result: CGMutableImageMetadata = switch policy {
        case .keepAll: removingTags(from: metadata) { stale.contains($0) }
        case .removeLocation: removingTags(from: metadata) { $0.hasPrefix("exif:GPS") || stale.contains($0) }
        case .removeAll: keeping(["tiff:Orientation"], from: metadata)
        }
        if let orientation {
            CGImageMetadataSetValueMatchingImageProperty(
                result, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFNumber
            )
        }
        return result
    }

    private static func orientationOnlyMetadata(_ orientation: Int) -> CGMutableImageMetadata {
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueMatchingImageProperty(
            metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFNumber
        )
        return metadata
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
        if target == .webp {
            try WebPWriter.write(source, plan: plan, name: url.lastPathComponent, to: temporary, token: token, progress: progress)
            return
        }
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
                let hdrBrightness = hdrMakerNote(properties)
                properties = properties.filter { key, _ in
                    [kCGImagePropertyOrientation, kCGImagePropertyGIFDictionary,
                     kCGImageDestinationLossyCompressionQuality].contains(key)
                }
                properties[kCGImagePropertyMakerAppleDictionary] = hdrBrightness
            }
            properties[kCGImagePropertyOrientation] = plan.outputOrientation
            let changesPixels = plan.appliesOrientation || plan.pixelCrop != nil || plan.resize != nil
            if changesPixels || plan.request.metadata == .removeAll {
                var image = try decodedFrame(source, index: index, name: url.lastPathComponent)
                if changesPixels {
                    image = try geometryApplied(to: image, plan: plan)
                    properties = removingStaleSize(properties)
                }
                CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            } else {
                CGImageDestinationAddImageFromSource(destination, source, index, properties as CFDictionary)
            }
            progress?(Double(index + 1) / Double(frames) * 0.95)
        }
        if plan.preservesHDR {
            try copyGainMaps(from: source, to: destination, plan: plan)
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
        if info.orientation != plan.outputOrientation {
            throw ConvertError.verificationFailed("orientation \(info.orientation), expected \(plan.outputOrientation)")
        }
        if plan.preservesHDR && !info.hasHDRGainMap {
            throw ConvertError.verificationFailed("the HDR gain map was lost")
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

    static func decodedFrame(_ source: CGImageSource, index: Int, name: String) throws -> CGImage {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw ConvertError.unreadable(name)
        }
        return image
    }

    /// Bakes orientation, then crops, then resizes, as the plan says.
    static func geometryApplied(to image: CGImage, plan: ConversionPlan) throws -> CGImage {
        var result = try PixelOps.orient(image, plan.bakedOrientation)
        if let crop = plan.pixelCrop { result = try PixelOps.crop(result, crop) }
        if let size = plan.resize { result = try PixelOps.resize(result, to: size) }
        return result
    }

    /// Size tags would describe the pixels before cropping or resizing.
    private static func removingStaleSize(_ properties: [CFString: Any]) -> [CFString: Any] {
        var properties = properties
        properties[kCGImagePropertyPixelWidth] = nil
        properties[kCGImagePropertyPixelHeight] = nil
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            properties[kCGImagePropertyExifDictionary] = exif
        }
        return properties
    }

    /// Copies the source's own gain map rather than re-deriving one, which
    /// keeps the SDR image and HDR highlights as the camera made them. The
    /// gain map gets the same rotation, crop and resize as the image.
    private static func copyGainMaps(from source: CGImageSource, to destination: CGImageDestination, plan: ConversionPlan) throws {
        let storedSize = PixelSize(
            width: (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int ?? 0,
            height: (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyPixelHeight] as? Int ?? 0
        )
        for type in [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap] {
            guard var info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [CFString: Any] else { continue }
            if plan.appliesOrientation || plan.pixelCrop != nil || plan.resize != nil {
                info = try transformedGainMap(info, plan: plan, imageSize: storedSize)
            }
            CGImageDestinationAddAuxiliaryDataInfo(destination, type, info as CFDictionary)
        }
    }

    private static func transformedGainMap(_ info: [CFString: Any], plan: ConversionPlan, imageSize: PixelSize) throws -> [CFString: Any] {
        guard let data = info[kCGImageAuxiliaryDataInfoData] as? Data,
              var description = info[kCGImageAuxiliaryDataInfoDataDescription] as? [String: Any],
              let width = description["Width"] as? Int, width > 0,
              let height = description["Height"] as? Int,
              let bytesPerRow = description["BytesPerRow"] as? Int,
              imageSize.width > 0, imageSize.height > 0
        else {
            throw ConvertError.verificationFailed("unreadable HDR gain map")
        }
        var bitmap = RawBitmap(
            data: data, width: width, height: height, bytesPerRow: bytesPerRow,
            bytesPerPixel: max(bytesPerRow / width, 1)
        ).oriented(plan.bakedOrientation)

        // The gain map is usually lower resolution; scale the crop to it.
        let baked = Orientation(exif: plan.bakedOrientation).apply(to: imageSize)
        let crop = plan.pixelCrop ?? PixelRect(x: 0, y: 0, width: baked.width, height: baked.height)
        let scaleX = Double(bitmap.width) / Double(baked.width)
        let scaleY = Double(bitmap.height) / Double(baked.height)
        if plan.pixelCrop != nil {
            let x0 = Int((Double(crop.x) * scaleX).rounded(.down))
            let y0 = Int((Double(crop.y) * scaleY).rounded(.down))
            let x1 = Int((Double(crop.maxX) * scaleX).rounded(.up))
            let y1 = Int((Double(crop.maxY) * scaleY).rounded(.up))
            let rect = PixelRect(x: x0, y: y0, width: max(x1 - x0, 1), height: max(y1 - y0, 1))
            bitmap = bitmap.cropped(to: rect.clamped(to: PixelSize(width: bitmap.width, height: bitmap.height)) ?? rect)
        }
        if let size = plan.resize {
            let target = PixelSize(
                width: max(Int((Double(bitmap.width) * Double(size.width) / Double(crop.width)).rounded()), 1),
                height: max(Int((Double(bitmap.height) * Double(size.height) / Double(crop.height)).rounded()), 1)
            )
            bitmap = try PixelOps.resize(bitmap, to: target)
        }
        description["Width"] = bitmap.width
        description["Height"] = bitmap.height
        description["BytesPerRow"] = bitmap.bytesPerRow
        var result = info
        result[kCGImageAuxiliaryDataInfoData] = bitmap.data
        result[kCGImageAuxiliaryDataInfoDataDescription] = description
        return result
    }

    /// Apple's gain maps need the HDR headroom values in maker-note tags 33
    /// and 48; without them the HDR renders dimmer (4.0× → 3.48× measured).
    /// They describe the image, not the person, so "remove all" keeps them.
    private static func hdrMakerNote(_ properties: [CFString: Any]) -> [String: Any]? {
        guard let maker = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any] else { return nil }
        let kept = maker.filter { ["33", "48"].contains($0.key) }
        return kept.isEmpty ? nil : kept
    }

    private static func orientation(of source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return properties?[kCGImagePropertyOrientation] as? Int ?? 1
    }

    private static func removingLocation(from metadata: CGImageMetadata) -> CGMutableImageMetadata {
        removingTags(from: metadata) { $0.hasPrefix("exif:GPS") }
    }

    private static func keeping(_ paths: Set<String>, from metadata: CGImageMetadata) -> CGMutableImageMetadata {
        removingTags(from: metadata) { !paths.contains($0) }
    }

    static func removingTags(from metadata: CGImageMetadata, where shouldRemove: (String) -> Bool) -> CGMutableImageMetadata {
        let copy = CGImageMetadataCreateMutableCopy(metadata) ?? CGImageMetadataCreateMutable()
        var doomed: [CFString] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, _ in
            doomed.append(path)
            return true
        }
        for path in doomed where shouldRemove(path as String) {
            CGImageMetadataRemoveTagWithPath(copy, nil, path)
        }
        return copy
    }
}
