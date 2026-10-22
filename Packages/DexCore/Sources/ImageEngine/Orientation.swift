import Foundation

/// An uncompressed bitmap, such as an HDR gain map from
/// `CGImageSourceCopyAuxiliaryDataInfoAtIndex`.
struct RawBitmap: Equatable {
    var data: Data
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var bytesPerPixel: Int
}

extension RawBitmap {
    /// Applies an EXIF orientation (1–8) so the result displays upright with
    /// orientation 1. A pure pixel shuffle: no resampling, no loss.
    func oriented(_ orientation: Int) -> RawBitmap {
        guard (2...8).contains(orientation) else { return self }
        let swaps = orientation >= 5
        let outWidth = swaps ? height : width
        let outHeight = swaps ? width : height
        let outBytesPerRow = outWidth * bytesPerPixel
        var output = Data(count: outBytesPerRow * outHeight)
        let (w, h, bpp) = (width, height, bytesPerPixel)

        data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
                for y in 0..<h {
                    for x in 0..<w {
                        // Where stored pixel (x, y) lands when displayed.
                        let (dx, dy): (Int, Int) = switch orientation {
                        case 2: (w - 1 - x, y)
                        case 3: (w - 1 - x, h - 1 - y)
                        case 4: (x, h - 1 - y)
                        case 5: (y, x)
                        case 6: (h - 1 - y, x)
                        case 7: (h - 1 - y, w - 1 - x)
                        default: (y, w - 1 - x)  // 8
                        }
                        let from = y * bytesPerRow + x * bpp
                        let to = dy * outBytesPerRow + dx * bpp
                        for byte in 0..<bpp {
                            out[to + byte] = input[from + byte]
                        }
                    }
                }
            }
        }
        return RawBitmap(data: output, width: outWidth, height: outHeight, bytesPerRow: outBytesPerRow, bytesPerPixel: bpp)
    }
}
