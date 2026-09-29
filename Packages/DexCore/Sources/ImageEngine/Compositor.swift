import CoreGraphics
import Foundation
import ImageIO
import JobSystem
import MediaModel

/// Draws a composition into one image. Inputs can be any readable format;
/// each is decoded, turned upright and colour-matched by Core Graphics.
enum Compositor {
    static func render(_ source: CGImageSource, plan: ConversionPlan, name: String, token: CancellationToken) throws -> CGImage {
        guard let composition = plan.request.composition else {
            throw ConvertError.encodeFailed(plan.request.target, reason: "nothing to compose")
        }
        // The base gets the user's rotate/flip and crop; resizing applies
        // to the finished composite.
        var basePlan = plan
        basePlan.resize = nil
        let base = try ImageEngine.geometryApplied(
            to: ImageEngine.decodedFrame(source, index: 0, name: name), plan: basePlan
        )
        let extras = try composition.extraImages.map { image -> CGImage in
            try token.check()
            return try upright(image.url)
        }
        let baseSize = PixelSize(width: base.width, height: base.height)

        let canvas: PixelSize
        var frames: [PixelRect] = []
        switch composition {
        case .layers:
            canvas = baseSize
        case .arrangement(let arrangement):
            let sizes = [baseSize] + extras.map { PixelSize(width: $0.width, height: $0.height) }
            let layout = ArrangementLayout.layout(sizes, arrangement)
            canvas = layout.canvas
            frames = layout.frames
        }

        let inputs = [base] + extras
        let deep = inputs.contains { $0.bitsPerComponent > 8 }
        let space = workingSpace(for: inputs)
        var info = CGImageAlphaInfo.premultipliedLast.rawValue
        if deep { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        guard let context = CGContext(
            data: nil, width: canvas.width, height: canvas.height, bitsPerComponent: deep ? 16 : 8,
            bytesPerRow: 0, space: space, bitmapInfo: info
        ) else {
            throw ConvertError.encodeFailed(plan.request.target, reason: "could not create the canvas")
        }
        context.interpolationQuality = .high
        let height = CGFloat(canvas.height)
        // Core Graphics counts y from the bottom; compositions from the top.
        func rect(_ r: PixelRect) -> CGRect {
            CGRect(x: r.x, y: Int(height) - r.maxY, width: r.width, height: r.height)
        }

        switch composition {
        case .layers(let layers):
            context.draw(base, in: rect(PixelRect(x: 0, y: 0, width: canvas.width, height: canvas.height)))
            for (layer, image) in zip(layers, extras) {
                try token.check()
                context.saveGState()
                context.translateBy(x: layer.centerX, y: height - layer.centerY)
                context.rotate(by: -layer.rotation * .pi / 180)
                context.setAlpha(min(max(layer.opacity, 0), 1))
                context.draw(image, in: CGRect(x: -layer.width / 2, y: -layer.height / 2, width: layer.width, height: layer.height))
                context.restoreGState()
            }
        case .arrangement(let arrangement):
            if case .color(let red, let green, let blue) = arrangement.background,
               let color = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, 1]) {
                context.setFillColor(color)
                context.fill(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
            }
            for (image, frame) in zip(inputs, frames) {
                try token.check()
                context.draw(image, in: rect(frame))
            }
        }

        guard var result = context.makeImage() else {
            throw ConvertError.encodeFailed(plan.request.target, reason: "could not finish the composite")
        }
        if let size = plan.resize {
            result = try PixelOps.resize(result, to: size)
        }
        return result
    }

    /// Full-resolution, orientation applied.
    private static func upright(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ConvertError.unreadable(url.lastPathComponent)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        return try PixelOps.orient(ImageEngine.decodedFrame(source, index: 0, name: url.lastPathComponent), orientation)
    }

    /// The base's RGB space, widened to Display P3 when any input is P3 so
    /// no colours are clipped. Grayscale bases work in sRGB.
    private static func workingSpace(for images: [CGImage]) -> CGColorSpace {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        if images.contains(where: { $0.colorSpace?.name == CGColorSpace.displayP3 }) { return p3 }
        if let space = images.first?.colorSpace, space.model == .rgb, !space.isHDR() { return space }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }
}
