import Accelerate
import CoreGraphics
import Foundation
import MediaModel

/// Geometry on decoded pixels. Orientation and crop are exact byte moves in
/// the image's own pixel format (straight alpha stays straight, 16-bit stays
/// 16-bit); only resize resamples.
enum PixelOps {
    /// Applies an EXIF orientation so the result is upright.
    static func orient(_ image: CGImage, _ exif: Int) throws -> CGImage {
        guard exif != 1 else { return image }
        guard image.bitsPerPixel % 8 == 0,
              let data = image.dataProvider?.data as Data?,
              let space = image.colorSpace
        else {
            throw ConvertError.encodeFailed(.png, reason: "unsupported pixel format for rotation")
        }
        let bitmap = RawBitmap(
            data: data, width: image.width, height: image.height,
            bytesPerRow: image.bytesPerRow, bytesPerPixel: image.bitsPerPixel / 8
        ).oriented(exif)
        guard let provider = CGDataProvider(data: bitmap.data as CFData),
              let result = CGImage(
                width: bitmap.width, height: bitmap.height,
                bitsPerComponent: image.bitsPerComponent, bitsPerPixel: image.bitsPerPixel,
                bytesPerRow: bitmap.bytesPerRow, space: space, bitmapInfo: image.bitmapInfo,
                provider: provider, decode: image.decode, shouldInterpolate: false,
                intent: image.renderingIntent
              )
        else {
            throw ConvertError.encodeFailed(.png, reason: "could not rebuild rotated image")
        }
        return result
    }

    static func crop(_ image: CGImage, _ rect: PixelRect) throws -> CGImage {
        guard let cropped = image.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)),
              cropped.width == rect.width, cropped.height == rect.height
        else {
            throw ConvertError.encodeFailed(.png, reason: "crop is outside the image")
        }
        return cropped
    }

    /// High-quality (Lanczos) resampling with vImage in the image's own
    /// colour space.
    static func resize(_ image: CGImage, to size: PixelSize) throws -> CGImage {
        let format = try resamplingFormat(for: image)
        var source = try vImage_Buffer(cgImage: image, format: format)
        defer { source.free() }
        var destination = try vImage_Buffer(
            width: size.width, height: size.height, bitsPerPixel: format.bitsPerPixel
        )
        defer { destination.free() }

        let flags = vImage_Flags(kvImageHighQualityResampling)
        let error: vImage_Error = switch (format.bitsPerComponent, format.bitsPerPixel / format.bitsPerComponent) {
        case (8, 4): vImageScale_ARGB8888(&source, &destination, nil, flags)
        case (8, 1): vImageScale_Planar8(&source, &destination, nil, flags)
        case (16, 4): vImageScale_ARGB16U(&source, &destination, nil, flags)
        case (16, 1): vImageScale_Planar16U(&source, &destination, nil, flags)
        default: vImageScale_ARGBFFFF(&source, &destination, nil, flags)
        }
        guard error == kvImageNoError else {
            throw ConvertError.encodeFailed(.png, reason: "resize failed (vImage \(error))")
        }
        return try destination.createCGImage(format: format)
    }

    /// Keeps depth, alpha and colour space; premultiplied alpha is the
    /// correct space for filtering.
    private static func resamplingFormat(for image: CGImage) throws -> vImage_CGImageFormat {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let deep = image.bitsPerComponent > 8
        let isFloat = image.bitmapInfo.contains(.floatComponents)

        if space.model == .monochrome && !hasAlpha && !isFloat {
            return try format(bits: deep ? 16 : 8, pixel: deep ? 16 : 8, space: space, info: CGImageAlphaInfo.none.rawValue
                | (deep ? CGBitmapInfo.byteOrder16Little.rawValue : 0))
        }
        let rgb = space.model == .rgb ? space : CGColorSpace(name: CGColorSpace.sRGB)!
        let alpha = (hasAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        if isFloat {
            return try format(bits: 32, pixel: 128, space: rgb,
                              info: alpha | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        }
        if deep {
            return try format(bits: 16, pixel: 64, space: rgb, info: alpha | CGBitmapInfo.byteOrder16Little.rawValue)
        }
        return try format(bits: 8, pixel: 32, space: rgb, info: alpha)
    }

    private static func format(bits: Int, pixel: Int, space: CGColorSpace, info: UInt32) throws -> vImage_CGImageFormat {
        guard let format = vImage_CGImageFormat(
            bitsPerComponent: bits, bitsPerPixel: pixel, colorSpace: space, bitmapInfo: CGBitmapInfo(rawValue: info)
        ) else {
            throw ConvertError.encodeFailed(.png, reason: "unsupported pixel format for resizing")
        }
        return format
    }

    /// Scales raw 8-bit gain-map pixels, nearest-neighbour for unusual
    /// channel counts.
    static func resize(_ bitmap: RawBitmap, to size: PixelSize) throws -> RawBitmap {
        guard size.width != bitmap.width || size.height != bitmap.height else { return bitmap }
        let bpp = bitmap.bytesPerPixel
        var output = Data(count: size.width * size.height * bpp)
        var input = bitmap.data
        let status: vImage_Error = input.withUnsafeMutableBytes { inBytes in
            output.withUnsafeMutableBytes { outBytes in
                var src = vImage_Buffer(data: inBytes.baseAddress, height: vImagePixelCount(bitmap.height),
                                        width: vImagePixelCount(bitmap.width), rowBytes: bitmap.bytesPerRow)
                var dst = vImage_Buffer(data: outBytes.baseAddress, height: vImagePixelCount(size.height),
                                        width: vImagePixelCount(size.width), rowBytes: size.width * bpp)
                let flags = vImage_Flags(kvImageHighQualityResampling)
                switch bpp {
                case 1: return vImageScale_Planar8(&src, &dst, nil, flags)
                case 4: return vImageScale_ARGB8888(&src, &dst, nil, flags)
                default:
                    let from = inBytes.bindMemory(to: UInt8.self)
                    let to = outBytes.bindMemory(to: UInt8.self)
                    for y in 0..<size.height {
                        let sy = y * bitmap.height / size.height
                        for x in 0..<size.width {
                            let sx = x * bitmap.width / size.width
                            for c in 0..<bpp {
                                to[(y * size.width + x) * bpp + c] = from[sy * bitmap.bytesPerRow + sx * bpp + c]
                            }
                        }
                    }
                    return kvImageNoError
                }
            }
        }
        guard status == kvImageNoError else {
            throw ConvertError.encodeFailed(.png, reason: "gain map resize failed")
        }
        return RawBitmap(data: output, width: size.width, height: size.height, bytesPerRow: size.width * bpp, bytesPerPixel: bpp)
    }
}

extension RawBitmap {
    /// Exact sub-rectangle copy.
    func cropped(to rect: PixelRect) -> RawBitmap {
        let rowLength = rect.width * bytesPerPixel
        var output = Data(count: rowLength * rect.height)
        data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { out in
                for row in 0..<rect.height {
                    let from = (rect.y + row) * bytesPerRow + rect.x * bytesPerPixel
                    out.baseAddress!.advanced(by: row * rowLength)
                        .copyMemory(from: input.baseAddress!.advanced(by: from), byteCount: rowLength)
                }
            }
        }
        return RawBitmap(data: output, width: rect.width, height: rect.height, bytesPerRow: rowLength, bytesPerPixel: bytesPerPixel)
    }
}
