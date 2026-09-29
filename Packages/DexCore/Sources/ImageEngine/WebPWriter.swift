import Accelerate
import CWebP
import CoreGraphics
import Foundation
import ImageIO
import JobSystem
import MediaModel

/// Encodes WebP with the vendored libwebp, since ImageIO can only read it.
///
/// Maximum quality is lossless WebP with `exact` set, so even the colour of
/// fully transparent pixels is kept. Colour profile and (filtered) metadata
/// go into ICCP and XMP chunks.
enum WebPWriter {
    static func write(
        _ source: CGImageSource,
        plan: ConversionPlan,
        name: String,
        to url: URL,
        token: CancellationToken,
        progress: (@Sendable (Double) -> Void)?
    ) throws {
        let image = if let composition = plan.request.composition, !composition.isEmpty {
            try Compositor.render(source, plan: plan, name: name, token: token)
        } else {
            try ImageEngine.geometryApplied(to: ImageEngine.decodedFrame(source, index: 0, name: name), plan: plan)
        }
        try token.check()

        let colorSpace = rgbColorSpace(of: image)
        let pixels = try rgbaPixels(image, in: colorSpace)
        defer { pixels.free() }
        try token.check()

        let bitstream = try encode(pixels, lossyQuality: plan.lossyQuality, token: token, progress: progress)
        let icc = embeddedProfile(colorSpace)
        let xmp = metadata(source, policy: plan.request.metadata)
        let output = (icc == nil && xmp == nil) ? bitstream : try mux(bitstream, icc: icc, xmp: xmp)
        try token.check()
        try output.write(to: url)
    }

    /// Encodes an already-rendered image (e.g. a PDF page), no metadata.
    static func write(_ image: CGImage, lossyQuality: Double?, to url: URL, token: CancellationToken) throws {
        let colorSpace = rgbColorSpace(of: image)
        let pixels = try rgbaPixels(image, in: colorSpace)
        defer { pixels.free() }
        let bitstream = try encode(pixels, lossyQuality: lossyQuality, token: token, progress: nil)
        let icc = embeddedProfile(colorSpace)
        try (icc == nil ? bitstream : try mux(bitstream, icc: icc, xmp: nil)).write(to: url)
    }

    // MARK: - Pixels

    /// WebP stores RGB only. Grayscale and CMYK are converted to sRGB (the
    /// planner discloses this); RGB spaces such as Display P3 are kept.
    private static func rgbColorSpace(of image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb, !space.isHDR() {
            return space
        }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// Straight (non-premultiplied) 8-bit RGBA, as libwebp expects.
    private static func rgbaPixels(_ image: CGImage, in colorSpace: CGColorSpace) throws -> vImage_Buffer {
        guard let format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        ) else {
            throw ConvertError.encodeFailed(.webp, reason: "unsupported colour space")
        }
        do {
            return try vImage_Buffer(cgImage: image, format: format)
        } catch {
            throw ConvertError.encodeFailed(.webp, reason: "could not read pixels (\(error))")
        }
    }

    // MARK: - Encoding

    private static func encode(
        _ pixels: vImage_Buffer,
        lossyQuality: Double?,
        token: CancellationToken,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> Data {
        var config = WebPConfig()
        if let quality = lossyQuality {
            guard WebPConfigPreset(&config, WEBP_PRESET_PHOTO, Float(quality * 100)) != 0 else {
                throw ConvertError.encodeFailed(.webp, reason: "invalid configuration")
            }
            config.method = 5
            config.use_sharp_yuv = 1
        } else {
            // Effort 3: on a 12 MP iPhone photo, 3.7 s and 5.62 MB versus 5.3 s
            // and 5.61 MB at effort 6 (release build, M4 Pro).
            guard WebPConfigInit(&config) != 0, WebPConfigLosslessPreset(&config, 3) != 0 else {
                throw ConvertError.encodeFailed(.webp, reason: "invalid configuration")
            }
            config.exact = 1
        }
        config.thread_level = 1
        guard WebPValidateConfig(&config) != 0 else {
            throw ConvertError.encodeFailed(.webp, reason: "invalid configuration")
        }

        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else {
            throw ConvertError.encodeFailed(.webp, reason: "out of memory")
        }
        defer { WebPPictureFree(&picture) }
        picture.width = Int32(pixels.width)
        picture.height = Int32(pixels.height)
        picture.use_argb = 1
        guard WebPPictureImportRGBA(
            &picture, pixels.data.assumingMemoryBound(to: UInt8.self), Int32(pixels.rowBytes)
        ) != 0 else {
            throw ConvertError.encodeFailed(.webp, reason: "out of memory")
        }

        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }

        let context = EncodeContext(token: token, progress: progress)
        let succeeded = withUnsafeMutablePointer(to: &writer) { writerPointer in
            withExtendedLifetime(context) {
                picture.writer = WebPMemoryWrite
                picture.custom_ptr = UnsafeMutableRawPointer(writerPointer)
                picture.user_data = Unmanaged.passUnretained(context).toOpaque()
                picture.progress_hook = { percent, picture in
                    guard let userData = picture?.pointee.user_data else { return 1 }
                    let context = Unmanaged<EncodeContext>.fromOpaque(userData).takeUnretainedValue()
                    context.progress?(Double(percent) / 100 * 0.9)
                    return context.token.isCancelled ? 0 : 1
                }
                return WebPEncode(&config, &picture) != 0
            }
        }
        guard succeeded else {
            if picture.error_code == VP8_ENC_ERROR_USER_ABORT { throw CancellationError() }
            throw ConvertError.encodeFailed(.webp, reason: "libwebp error \(picture.error_code.rawValue)")
        }
        return Data(bytes: writer.mem, count: writer.size)
    }

    private final class EncodeContext {
        let token: CancellationToken
        let progress: (@Sendable (Double) -> Void)?

        init(token: CancellationToken, progress: (@Sendable (Double) -> Void)?) {
            self.token = token
            self.progress = progress
        }
    }

    // MARK: - Metadata

    /// sRGB is WebP's default, so its profile is omitted to save space.
    private static func embeddedProfile(_ colorSpace: CGColorSpace) -> Data? {
        guard colorSpace.name != CGColorSpace.sRGB else { return nil }
        return colorSpace.copyICCData() as Data?
    }

    /// Metadata as XMP, filtered by the policy. Orientation and pixel
    /// dimensions are dropped because the pixels are already upright.
    private static func metadata(_ source: CGImageSource, policy: MetadataPolicy) -> Data? {
        guard policy != .removeAll, let original = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return nil }
        let stale: Set<String> = ["tiff:Orientation", "exif:PixelXDimension", "exif:PixelYDimension"]
        let filtered = ImageEngine.removingTags(from: original) { path in
            stale.contains(path) || (policy == .removeLocation && path.hasPrefix("exif:GPS"))
        }
        return CGImageMetadataCreateXMPData(filtered, nil) as Data?
    }

    private static func mux(_ bitstream: Data, icc: Data?, xmp: Data?) throws -> Data {
        try bitstream.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            var image = WebPData(bytes: raw.bindMemory(to: UInt8.self).baseAddress, size: raw.count)
            guard let mux = WebPMuxCreate(&image, 1) else {
                throw ConvertError.encodeFailed(.webp, reason: "could not add metadata")
            }
            defer { WebPMuxDelete(mux) }
            for (fourcc, payload) in [("ICCP", icc), ("XMP ", xmp)] {
                guard let payload else { continue }
                let status = payload.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> WebPMuxError in
                    var chunk = WebPData(bytes: bytes.bindMemory(to: UInt8.self).baseAddress, size: bytes.count)
                    return WebPMuxSetChunk(mux, fourcc, &chunk, 1)
                }
                guard status == WEBP_MUX_OK else {
                    throw ConvertError.encodeFailed(.webp, reason: "could not add \(fourcc) chunk")
                }
            }
            var assembled = WebPData()
            guard WebPMuxAssemble(mux, &assembled) == WEBP_MUX_OK else {
                throw ConvertError.encodeFailed(.webp, reason: "could not assemble file")
            }
            defer { WebPDataClear(&assembled) }
            return Data(bytes: assembled.bytes, count: assembled.size)
        }
    }
}
