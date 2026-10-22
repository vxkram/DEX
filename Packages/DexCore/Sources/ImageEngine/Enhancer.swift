import CoreGraphics
import CoreImage
import CoreML
import CryptoKit
import Foundation
import JobSystem
import MediaModel
import Vision

public enum EnhanceError: Error, Equatable, CustomStringConvertible {
    case modelMissing(EnhanceModel)
    case badDownload(EnhanceModel)
    case failed(String)

    public var description: String {
        switch self {
        case .modelMissing(let model): "The \(model.title) model isn't downloaded yet."
        case .badDownload(let model): "The \(model.title) model didn't match its published checksum, so it wasn't installed."
        case .failed(let reason): "Enhancing failed: \(reason)"
        }
    }
}

/// Where downloaded models live, compiled for this Mac.
public enum EnhanceModels {
    /// Application Support/DEX/Models (inside the app's container when
    /// sandboxed). `DEX_MODELS_DIR` overrides it for tests.
    public static var folder: URL {
        if let override = ProcessInfo.processInfo.environment["DEX_MODELS_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DEX/Models", isDirectory: true)
    }

    public static func compiledURL(_ model: EnhanceModel) -> URL {
        folder.appendingPathComponent(model.rawValue + ".mlmodelc", isDirectory: true)
    }

    public static func isInstalled(_ model: EnhanceModel) -> Bool {
        FileManager.default.fileExists(atPath: compiledURL(model).path)
    }

    /// Bytes on disk, nil when not installed.
    public static func installedSize(_ model: EnhanceModel) -> Int64? {
        let url = compiledURL(model)
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return isInstalled(model) ? total : nil
    }

    /// Verifies a downloaded zip against the pinned size and SHA-256,
    /// unpacks it and compiles it for this Mac. The zip is deleted either way.
    public static func install(_ model: EnhanceModel, from zip: URL) async throws {
        defer { try? FileManager.default.removeItem(at: zip) }
        try await MediaWork.run { _ in
            let data = try Data(contentsOf: zip, options: .alwaysMapped)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard Int64(data.count) == model.bytes, digest == model.sha256 else { throw EnhanceError.badDownload(model) }

            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("dex-model-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zip.path, scratch.path]
            try unzip.run()
            unzip.waitUntilExit()
            let package = scratch.appendingPathComponent(model.rawValue + ".mlpackage")
            guard unzip.terminationStatus == 0, FileManager.default.fileExists(atPath: package.path) else {
                throw EnhanceError.failed("the \(model.title) download couldn't be unpacked")
            }
            let compiled = try MLModel.compileModel(at: package)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = compiledURL(model)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: compiled, to: destination)
            ModelCache.shared.forget(model)
        }
    }

    public static func remove(_ model: EnhanceModel) {
        ModelCache.shared.forget(model)
        try? FileManager.default.removeItem(at: compiledURL(model))
    }
}

/// Loaded models, kept for the next tile or image.
final class ModelCache: @unchecked Sendable {
    static let shared = ModelCache()
    private let lock = NSLock()
    private var models: [EnhanceModel: MLModel] = [:]

    func model(_ id: EnhanceModel) throws -> MLModel {
        try lock.withLock {
            if let model = models[id] { return model }
            guard EnhanceModels.isInstalled(id) else { throw EnhanceError.modelMissing(id) }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let model = try MLModel(contentsOf: EnhanceModels.compiledURL(id), configuration: configuration)
            models[id] = model
            return model
        }
    }

    func forget(_ id: EnhanceModel) {
        lock.withLock { models[id] = nil }
    }
}

/// Runs the models: 4× upscaling in overlapping tiles, then optional face
/// restoration, then 2× if asked (a Lanczos downscale of the 4× result).
enum Enhancer {
    static let modelScale = 4

    static func enhance(
        _ image: CGImage, _ settings: Enhancement,
        token: CancellationToken? = nil, progress: ((Double) -> Void)? = nil
    ) throws -> CGImage {
        let upscaler = try ModelCache.shared.model(settings.upscaler)
        let faces = settings.faces ? try ModelCache.shared.model(.faces) : nil
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: space, .cacheIntermediates: false])

        var result = try upscale(image, with: upscaler, space: space, context: context, token: token) { done in
            progress?(done * (faces == nil ? 1 : 0.9))
        }
        if let faces {
            result = try restoreFaces(in: result, with: faces, space: space, context: context, token: token)
            progress?(1)
        }
        if settings.scale != modelScale {
            result = try PixelOps.resize(result, to: settings.output(for: PixelSize(width: image.width, height: image.height)))
        }
        return result
    }

    // MARK: - Upscaling

    private static func upscale(
        _ image: CGImage, with model: MLModel, space: CGColorSpace, context: CIContext,
        token: CancellationToken?, progress: (Double) -> Void
    ) throws -> CGImage {
        let side = 256, scale = modelScale
        let width = image.width, height = image.height
        guard let canvas = CGContext(
            data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw EnhanceError.failed("not enough memory for a \(width * scale) × \(height * scale) result")
        }
        // Edge pixels repeat outward, so tiles past a small image's edge see
        // the picture continue rather than black.
        let source = CIImage(cgImage: image).clampedToExtent()
        let tiles = EnhanceTiling.tiles(for: PixelSize(width: width, height: height), side: side)
        let buffer = try pixelBuffer(side: side)
        let outputSide = side * scale

        for (index, tile) in tiles.enumerated() {
            try token?.check()
            // Tiles count from the top; Core Image from the bottom.
            let window = CGRect(x: tile.window.x, y: height - tile.window.y - side, width: side, height: side)
            let input = source.cropped(to: window).transformed(by: CGAffineTransform(translationX: -window.minX, y: -window.minY))
            context.render(input, to: buffer, bounds: CGRect(x: 0, y: 0, width: side, height: side), colorSpace: space)

            let output = try predict(model, buffer)
            let keep = CGRect(x: tile.keep.x * scale, y: outputSide - tile.keep.maxY * scale,
                              width: tile.keep.width * scale, height: tile.keep.height * scale)
            guard let part = context.createCGImage(CIImage(cvPixelBuffer: output, options: [.colorSpace: space]),
                                                   from: keep, format: .RGBA8, colorSpace: space)
            else { throw EnhanceError.failed("a tile couldn't be read back") }
            canvas.draw(part, in: CGRect(x: tile.target.x * scale, y: (height - tile.target.maxY) * scale,
                                         width: tile.target.width * scale, height: tile.target.height * scale))
            progress(Double(index + 1) / Double(tiles.count))
        }
        guard var result = canvas.makeImage() else { throw EnhanceError.failed("the result couldn't be finished") }

        // The models only see colour; transparency is enlarged on its own.
        if ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) {
            let alpha = try PixelOps.resize(image, to: PixelSize(width: width * scale, height: height * scale))
            let masked = CIImage(cgImage: result).applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: CIImage(cgImage: alpha),
            ])
            if let image = context.createCGImage(masked, from: CGRect(x: 0, y: 0, width: width * scale, height: height * scale),
                                                 format: .RGBA8, colorSpace: space) {
                result = image
            }
        }
        return result
    }

    private static func pixelBuffer(side: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer
        else { throw EnhanceError.failed("couldn't make an image buffer") }
        return buffer
    }

    private static func predict(_ model: MLModel, _ buffer: CVPixelBuffer) throws -> CVPixelBuffer {
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
        guard let output = try model.prediction(from: input).featureValue(for: "output")?.imageBufferValue else {
            throw EnhanceError.failed("the model returned no image")
        }
        return output
    }

    // MARK: - Faces

    /// GFPGAN's 512² template: eyes, nose tip, mouth corners (y from the top).
    private static let template: [CGPoint] = [
        CGPoint(x: 192.98, y: 239.95), CGPoint(x: 318.90, y: 240.19), CGPoint(x: 256.63, y: 314.02),
        CGPoint(x: 201.26, y: 371.41), CGPoint(x: 313.09, y: 371.15),
    ]

    /// Faces narrower than this are left alone: the model invents too much.
    static let minimumFaceWidth = 48

    private static func restoreFaces(
        in image: CGImage, with model: MLModel, space: CGColorSpace, context: CIContext, token: CancellationToken?
    ) throws -> CGImage {
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        let size = CGSize(width: image.width, height: image.height)
        let faces = (request.results ?? []).filter { $0.boundingBox.width * size.width >= CGFloat(minimumFaceWidth) }
        guard !faces.isEmpty else { return image }

        let side = 512
        let buffer = try pixelBuffer(side: side)
        let whole = CGRect(origin: .zero, size: size)
        var result = CIImage(cgImage: image)
        // Soft-edged square in face space, so a restored face blends in.
        let mask = CIImage(color: .white).cropped(to: CGRect(x: 40, y: 40, width: side - 80, height: side - 80))
            .applyingGaussianBlur(sigma: 18).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))

        for face in faces {
            try token?.check()
            guard let points = landmarks(face, size: size) else { continue }
            // Vision and Core Image count y from the bottom; the template from the top.
            let target = template.map { CGPoint(x: $0.x, y: CGFloat(side) - $0.y) }
            let toFace = similarity(from: points, to: target)
            let aligned = result.transformed(by: toFace).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
            context.render(aligned, to: buffer, bounds: CGRect(x: 0, y: 0, width: side, height: side), colorSpace: space)
            let restored = CIImage(cvPixelBuffer: try predict(model, buffer), options: [.colorSpace: space])
            let back = toFace.inverted()
            result = restored.transformed(by: back).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: result,
                kCIInputMaskImageKey: mask.transformed(by: back),
            ]).cropped(to: whole)
        }
        guard let output = context.createCGImage(result, from: whole, format: .RGBA8, colorSpace: space) else {
            throw EnhanceError.failed("the restored faces couldn't be finished")
        }
        return output
    }

    /// Eye centres, nose tip and mouth corners in image pixels (y up), left to right.
    private static func landmarks(_ face: VNFaceObservation, size: CGSize) -> [CGPoint]? {
        guard let marks = face.landmarks, let left = marks.leftEye, let right = marks.rightEye,
              let nose = marks.nose, let lips = marks.outerLips
        else { return nil }
        func points(_ region: VNFaceLandmarkRegion2D) -> [CGPoint] { region.pointsInImage(imageSize: size) }
        func centre(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
            let all = points(region)
            return CGPoint(x: all.map(\.x).reduce(0, +) / CGFloat(all.count), y: all.map(\.y).reduce(0, +) / CGFloat(all.count))
        }
        let eyes = [centre(left), centre(right)].sorted { $0.x < $1.x }
        guard let tip = points(nose).min(by: { $0.y < $1.y }),
              let mouthLeft = points(lips).min(by: { $0.x < $1.x }),
              let mouthRight = points(lips).max(by: { $0.x < $1.x })
        else { return nil }
        return [eyes[0], eyes[1], tip, mouthLeft, mouthRight]
    }

    /// Least-squares rotation, uniform scale and shift taking `source` onto `target`.
    static func similarity(from source: [CGPoint], to target: [CGPoint]) -> CGAffineTransform {
        let n = CGFloat(source.count)
        let sx = source.map(\.x).reduce(0, +) / n, sy = source.map(\.y).reduce(0, +) / n
        let tx = target.map(\.x).reduce(0, +) / n, ty = target.map(\.y).reduce(0, +) / n
        var dot: CGFloat = 0, cross: CGFloat = 0, norm: CGFloat = 0
        for (p, q) in zip(source, target) {
            let px = p.x - sx, py = p.y - sy, qx = q.x - tx, qy = q.y - ty
            dot += px * qx + py * qy
            cross += px * qy - py * qx
            norm += px * px + py * py
        }
        let a = dot / max(norm, .ulpOfOne), b = cross / max(norm, .ulpOfOne)
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx - (a * sx - b * sy), ty: ty - (b * sx + a * sy))
    }
}

extension ImageEngine {
    /// A quick look at Enhance for the stage: the (upright) preview, turned
    /// and cropped as edited, shrunk to at most `maxInput` pixels on its long
    /// side, then enhanced. The export runs on the full-resolution pixels.
    public static func enhancedPreview(
        _ preview: PreviewImage, orientation: Orientation, crop: PixelRect?, display: PixelSize,
        settings: Enhancement, maxInput: Int = 640
    ) async throws -> PreviewImage {
        try await MediaWork.run { token in
            // The models work in 8-bit sRGB; an HDR preview is mapped down first.
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
            let source = preview.cgImage
            guard let context = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw EnhanceError.failed("couldn't prepare the preview") }
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            guard var image = context.makeImage() else { throw EnhanceError.failed("couldn't prepare the preview") }
            image = try PixelOps.orient(image, orientation.exif)
            if let crop, display.width > 0 {
                let scale = Double(image.width) / Double(display.width)
                let rect = PixelRect(x: Int(Double(crop.x) * scale), y: Int(Double(crop.y) * scale),
                                     width: max(Int(Double(crop.width) * scale), 1), height: max(Int(Double(crop.height) * scale), 1))
                if let clamped = rect.clamped(to: PixelSize(width: image.width, height: image.height)) {
                    image = try PixelOps.crop(image, clamped)
                }
            }
            let longest = max(image.width, image.height)
            if longest > maxInput {
                let factor = Double(maxInput) / Double(longest)
                image = try PixelOps.resize(image, to: PixelSize(width: max(Int(Double(image.width) * factor), 1),
                                                                 height: max(Int(Double(image.height) * factor), 1)))
            }
            return PreviewImage(cgImage: try Enhancer.enhance(image, settings, token: token))
        }
    }
}
