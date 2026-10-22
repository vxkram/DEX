import CoreGraphics
import Foundation
import ImageIO
import JobSystem
import MediaModel

/// Generates deterministic test images with ImageIO so no binary fixtures
/// need to live in the repository.
struct FixtureFactory: Sendable {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dex-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    struct Spec: @unchecked Sendable {
        var width = 64
        var height = 48
        var alpha = false
        var bitsPerComponent = 8
        var colorSpace: CFString = CGColorSpace.sRGB
        var orientation = 1
        var gps = false
        var frames = 1
        /// Per-frame GIF delays in seconds (default: whatever ImageIO writes).
        var delays: [Double]?
        /// Deterministic per-pixel noise, like a real photo's grain.
        var noise = false
        /// Fill with one colour instead of the gradient (0...1 sRGB).
        var solid: (Double, Double, Double)?
    }

    /// Encodes on MediaWork's queue: ImageIO's HEIF/AVIF encoder deadlocks
    /// when the Swift cooperative pool is saturated (3-core CI runners).
    func image(_ format: ImageFormat, named name: String? = nil, _ spec: Spec = Spec()) async throws -> URL {
        try await MediaWork.run { _ in try self.encodeImage(format, named: name, spec) }
    }

    func hdrImage(_ format: ImageFormat, width: Int = 64, height: Int = 48) async throws -> URL {
        try await MediaWork.run { _ in try self.encodeHDRImage(format, width: width, height: height) }
    }

    private func encodeImage(_ format: ImageFormat, named name: String?, _ spec: Spec) throws -> URL {
        let url = directory.appendingPathComponent(name ?? "fixture.\(format.preferredFileExtension)")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, format.typeIdentifier as CFString, spec.frames, nil
        ) else {
            throw FixtureError.unsupported(format)
        }
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: spec.orientation]
        if spec.gps {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 12.97,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 77.59,
                kCGImagePropertyGPSLongitudeRef: "E",
            ]
        }
        for frame in 0..<spec.frames {
            var frameProperties = properties
            if let delays = spec.delays {
                frameProperties[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: delays[frame]]
            }
            CGImageDestinationAddImage(destination, try makeImage(spec, seed: frame), frameProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.encodeFailed(format) }
        return url
    }

    func file(named name: String, contents: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    /// An HDR image with an ISO gain map, encoded by ImageIO from a
    /// float image whose highlights reach 4× SDR white.
    private func encodeHDRImage(_ format: ImageFormat, width: Int, height: Int) throws -> URL {
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue
              )
        else { throw FixtureError.context }
        for x in 0..<width {
            let brightness = 0.2 + 3.8 * CGFloat(x) / CGFloat(width - 1)
            context.setFillColor(CGColor(colorSpace: space, components: [brightness, brightness * 0.9, brightness * 0.7, 1])!)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        guard let base = context.makeImage(), let image = CGImageCreateCopyWithContentHeadroom(4, base) else { throw FixtureError.context }
        let url = directory.appendingPathComponent("hdr.\(format.preferredFileExtension)")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.typeIdentifier as CFString, 1, nil) else {
            throw FixtureError.unsupported(format)
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.encodeFailed(format) }
        return url
    }

    /// A 1×1 lossless WebP, since ImageIO cannot encode WebP.
    func webp() throws -> URL {
        let data = Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")!
        return try file(named: "fixture.webp", contents: data)
    }

    private func makeImage(_ spec: Spec, seed: Int) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: spec.colorSpace) else { throw FixtureError.colorSpace }
        let alphaInfo: CGImageAlphaInfo = spec.alpha ? .premultipliedLast : .noneSkipLast
        var bitmapInfo = alphaInfo.rawValue
        if spec.bitsPerComponent == 16 { bitmapInfo |= CGBitmapInfo.byteOrder16Little.rawValue }
        guard let context = CGContext(
            data: nil,
            width: spec.width,
            height: spec.height,
            bitsPerComponent: spec.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw FixtureError.context
        }
        if let (r, g, b) = spec.solid {
            context.setFillColor(red: r, green: g, blue: b, alpha: spec.alpha ? 0.5 : 1)
            context.fill(CGRect(x: 0, y: 0, width: spec.width, height: spec.height))
            guard let image = context.makeImage() else { throw FixtureError.context }
            return image
        }
        // A simple gradient plus a seed-dependent block, so frames differ.
        for x in 0..<spec.width {
            let t = CGFloat(x) / CGFloat(max(spec.width - 1, 1))
            context.setFillColor(red: t, green: 1 - t, blue: 0.5, alpha: spec.alpha ? 0.5 : 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: spec.height))
        }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: seed % max(spec.width - 8, 1), y: 0, width: 8, height: 8))
        if spec.noise {
            var state: UInt32 = 0x9E37_79B9
            for y in 0..<spec.height {
                for x in 0..<spec.width {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    let grain = CGFloat(state >> 24) / 255
                    context.setFillColor(red: grain, green: grain * 0.8, blue: 1 - grain, alpha: 0.35)
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        guard let image = context.makeImage() else { throw FixtureError.context }
        return image
    }
}

enum FixtureError: Error {
    case unsupported(ImageFormat)
    case encodeFailed(ImageFormat)
    case colorSpace
    case context
}
