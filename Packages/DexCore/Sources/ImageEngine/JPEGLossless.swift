import CJPEGTurbo
import Foundation
import MediaModel

/// Lossless JPEG operations on the compressed data (libjpeg-turbo).
enum JPEGLossless {
    struct Info {
        var blockSize: PixelSize
        var progressive: Bool
    }

    static func info(of data: Data) -> Info? {
        var info = dx_jpeg_info()
        var error = [CChar](repeating: 0, count: 256)
        let ok = data.withUnsafeBytes { bytes in
            dx_jpeg_read_info(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &info, &error, error.count)
        }
        guard ok != 0, info.mcu_width > 0, info.mcu_height > 0 else { return nil }
        return Info(
            blockSize: PixelSize(width: Int(info.mcu_width), height: Int(info.mcu_height)),
            progressive: info.progressive != 0
        )
    }

    /// Optionally crops on block boundaries (the rect must already be
    /// snapped), and always Huffman-optimises the result. Only ICC profiles
    /// are carried; the caller rewrites the rest of the metadata.
    static func transform(_ data: Data, crop rect: PixelRect?, progressive: Bool) throws -> Data {
        var options = dx_jpeg_options()
        if let rect {
            options.crop = 1
            options.crop_x = UInt32(rect.x)
            options.crop_y = UInt32(rect.y)
            options.crop_width = UInt32(rect.width)
            options.crop_height = UInt32(rect.height)
        }
        options.optimize = 1
        options.progressive = progressive ? 1 : 0

        var output: UnsafeMutablePointer<UInt8>?
        var outputSize = 0
        var error = [CChar](repeating: 0, count: 256)
        let ok = data.withUnsafeBytes { bytes in
            dx_jpeg_transform(
                bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &options,
                &output, &outputSize, &error, error.count
            )
        }
        guard ok != 0, let output else {
            let message = String(decoding: error.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            throw ConvertError.encodeFailed(.jpeg, reason: message.isEmpty ? "lossless crop failed" : message)
        }
        defer { dx_jpeg_free(output) }
        return Data(bytes: output, count: outputSize)
    }
}
