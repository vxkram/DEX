import CoreGraphics
import CoreImage
import MediaModel

extension PixelOps {
    /// Fit: puts the whole image on a canvas of the frame's ratio. The
    /// image is drawn 1:1 at whole-pixel offsets, so its own pixels are
    /// copied, never resampled; only the background around it is new.
    /// `opaque` targets get white instead of transparency.
    static func frame(_ image: CGImage, _ framing: Framing, opaque: Bool) throws -> CGImage {
        let size = PixelSize(width: image.width, height: image.height)
        let (canvas, rect) = framing.canvas(for: size)
        let deep = image.bitsPerComponent > 8
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var info = CGImageAlphaInfo.premultipliedLast.rawValue
        if deep { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        guard let context = CGContext(
            data: nil, width: canvas.width, height: canvas.height, bitsPerComponent: deep ? 16 : 8,
            bytesPerRow: 0, space: space, bitmapInfo: info
        ) else {
            throw ConvertError.encodeFailed(.png, reason: "could not create the Fit canvas")
        }
        let whole = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

        var background = framing.background
        if background == .transparent && opaque { background = .white }
        switch background {
        case .transparent:
            break
        case .color(let red, let green, let blue):
            context.setFillColor(CGColor(colorSpace: srgb, components: [red, green, blue, 1])!)
            context.fill(whole)
        case .blur:
            if let blurred = blurredCover(image, canvas: canvas, space: space) {
                context.draw(blurred, in: whole)
            }
            // Darkened a little so the picture stands out from it.
            context.setFillColor(CGColor(colorSpace: srgb, components: [0, 0, 0, 0.18])!)
            context.fill(whole)
        }

        // Core Graphics counts y from the bottom.
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: rect.x, y: canvas.height - rect.maxY, width: rect.width, height: rect.height))
        guard let result = context.makeImage() else {
            throw ConvertError.encodeFailed(.png, reason: "could not finish the Fit canvas")
        }
        return result
    }

    /// The image scaled to cover the canvas and heavily blurred: shrunk to a
    /// few dozen pixels, then grown back in softened doubling steps, which is
    /// smooth at any size and cheap even for very large canvases.
    private static func blurredCover(_ image: CGImage, canvas: PixelSize, space: CGColorSpace) -> CGImage? {
        let cover = max(Double(canvas.width) / Double(image.width), Double(canvas.height) / Double(image.height))
        let target = Double(max(image.width, image.height)) * cover
        var scale = 32.0 / Double(max(image.width, image.height))
        // Clamped first, so no edge ever samples the transparency outside.
        var step = CIImage(cgImage: image).clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(x: 0, y: 0, width: (Double(image.width) * scale).rounded(.down),
                                height: (Double(image.height) * scale).rounded(.down)))
        while Double(max(step.extent.width, step.extent.height)) < min(512, target) {
            let extent = step.extent
            step = step.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: 2, y: 2))
                .applyingGaussianBlur(sigma: 1.5)
                .cropped(to: CGRect(x: extent.minX * 2, y: extent.minY * 2, width: extent.width * 2, height: extent.height * 2))
            scale *= 2
        }
        let grow = cover / scale
        let width = Double(image.width) * cover, height = Double(image.height) * cover
        let placed = step.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: grow, y: grow))
            .transformed(by: CGAffineTransform(translationX: (Double(canvas.width) - width) / 2 - step.extent.minX * grow,
                                               y: (Double(canvas.height) - height) / 2 - step.extent.minY * grow))
            .cropped(to: CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
        let context = CIContext(options: [.workingColorSpace: space, .cacheIntermediates: false])
        return context.createCGImage(placed, from: placed.extent, format: .RGBA8, colorSpace: space)
    }
}
