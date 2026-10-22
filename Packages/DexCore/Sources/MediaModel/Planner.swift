/// Decides how a conversion will be done and what it will cost in quality.
///
/// Pure and deterministic: the same inputs always give the same plan, so the
/// UI can show the verdict live and tests can cover every combination.
public enum Planner {
    /// Refuse images above this size before decoding them.
    public static let maxMegapixels = 500

    /// Candidates offered when a lossy conversion has a lossless way out.
    static let losslessFallbacks: [ImageFormat] = [.png, .tiff]

    public static func plan(
        _ source: MediaInfo,
        _ request: ConvertRequest,
        writable: Set<ImageFormat>
    ) throws -> ConversionPlan {
        guard let sourceFormat = source.format else {
            throw PlanError.unsupportedSource(source.typeIdentifier)
        }
        guard writable.contains(request.target) else {
            throw PlanError.unsupportedTarget(request.target)
        }
        let megapixels = source.pixelWidth * source.pixelHeight / 1_000_000
        guard megapixels <= maxMegapixels else {
            throw PlanError.tooLarge(megapixels: megapixels)
        }

        var plan = baselinePlan(source, sourceFormat: sourceFormat, request: request)
        plan.verdict = plan.strategy == .reencode || plan.notes.contains(where: \.isLoss)
            ? (plan.notes.contains(where: \.isLoss) ? .lossy : .lossless)
            : .noReencode
        if plan.verdict == .lossy {
            plan.losslessAlternative = losslessFallbacks.first { candidate in
                guard candidate != request.target, writable.contains(candidate) else { return false }
                var alternative = request
                alternative.target = candidate
                let fallback = try? Planner.plan(source, alternative, writable: [candidate])
                return fallback.map { $0.verdict != .lossy } ?? false
            }
        }
        return plan
    }

    private static func baselinePlan(
        _ source: MediaInfo,
        sourceFormat: ImageFormat,
        request: ConvertRequest
    ) -> ConversionPlan {
        let target = request.target
        let geometry = request.geometry

        // Everything the user sees is in display space: the file's own
        // orientation followed by their rotate/flip.
        let total = Orientation(exif: source.orientation).followed(by: geometry.orientation)
        let displaySize = total.apply(to: source.storedSize)
        let fullFrame = PixelRect(x: 0, y: 0, width: displaySize.width, height: displaySize.height)
        let crop = geometry.crop?.clamped(to: displaySize).flatMap { $0 == fullFrame ? nil : $0 }
        let croppedSize = crop?.size ?? displaySize
        // A frame that wouldn't add anything (the picture already has its
        // shape) is no frame.
        let frame = geometry.frame.flatMap { $0.canvas(for: croppedSize).canvas == croppedSize ? nil : $0 }
        let framedSize = frame?.canvas(for: croppedSize).canvas ?? croppedSize
        let resize = geometry.resize.flatMap { $0 == framedSize || $0.width < 1 || $0.height < 1 ? nil : $0 }
        let changesPixels = crop != nil || frame != nil || resize != nil

        if let composition = request.composition, !composition.isEmpty {
            return compositePlan(
                source, sourceFormat: sourceFormat, request: request, composition: composition,
                orientation: total, crop: crop, frame: frame, baseSize: framedSize, resize: resize
            )
        }

        var strategy = ConversionStrategy.reencode
        var losses: [QualityNote] = []
        var info: [QualityNote] = []
        var outputOrientation = source.orientation
        var bakedOrientation = 1
        var pixelCrop: PixelRect?
        var displayCrop = crop
        var outputSize = source.storedSize
        var preservesHDR = source.hasHDRGainMap && target.supportsGainMap

        // A lower quality on a lossy format means the user wants a
        // re-encode, even into the same format.
        let wantsLossy = target.hasLossyMode && request.quality != .maximum
        // Lossless compression only applies where a repack exists.
        let optimizes = request.optimize && sourceFormat == target && target.canOptimizeLosslessly

        // 1. Same format without new pixels: copy, or rewrite metadata
        //    (including a new orientation tag for rotate/flip).
        if sourceFormat == target && !changesPixels && !wantsLossy && !optimizes {
            let changesMetadata = !geometry.orientation.isIdentity
                || request.metadata == .removeAll
                || (request.metadata == .removeLocation && source.hasGPS)
            if !changesMetadata {
                strategy = .copyFile
            } else if target == .jpeg && request.metadata == .removeAll && source.jpegBlockSize != nil && !source.hasHDRGainMap {
                // Handled below by libjpeg-turbo, which writes no metadata
                // padding (ImageIO's rewrite adds ~2–3 KB).
            } else if target.supportsLosslessMetadataEdit && target.supportsOrientationTag {
                strategy = .rewriteMetadata
                outputOrientation = total.exif
            } else if !target.reencodesLosslessly {
                losses.append(.metadataEditRequiresReencode(target))
            }
        }

        // 2. JPEG crop and/or optimisation on the compressed data: no
        //    decode, no loss.
        if strategy == .reencode, sourceFormat == .jpeg, target == .jpeg, resize == nil, frame == nil, !wantsLossy,
           (crop != nil && !geometry.exactCrop) || (crop == nil && (optimizes || request.metadata == .removeAll)),
           let block = source.jpegBlockSize {
            strategy = .losslessJPEGTransform
            outputOrientation = total.exif
            if let crop {
                let stored = snapped(total.inverse.apply(to: crop, in: displaySize), to: block, within: source.storedSize)
                let shown = total.apply(to: stored, in: source.storedSize)
                pixelCrop = stored
                displayCrop = shown
                outputSize = stored.size
                if shown != crop { info.append(.cropSnapped(to: shown)) }
            }
            if optimizes { info.append(.optimisedLosslessly) }
            if source.hasHDRGainMap {
                preservesHDR = false
                losses.append(.hdrNotKeptByLosslessCrop)
            }
        }

        var frames = source.frameCount
        var lossyQuality: Double?
        if strategy == .reencode {
            let formatCantRotate = !total.isIdentity && !target.supportsOrientationTag
            if changesPixels || formatCantRotate {
                // Work upright: bake the orientation, then crop, frame and resize.
                bakedOrientation = total.exif
                outputOrientation = 1
                pixelCrop = crop
                outputSize = resize ?? framedSize
                if formatCantRotate && !changesPixels { info.append(.orientationApplied) }
                if let frame { info.append(.framed(to: framedSize, background: frame.background)) }
                if let resize { losses.append(.resampled(from: framedSize, to: resize)) }
            } else {
                outputOrientation = total.exif
            }
            let lossyWebP = target == .webp && request.quality != .maximum
            if (!target.supportsLossless && target != .gif) || lossyWebP {
                lossyQuality = request.quality.lossyValue
                // After the reason a re-encode is needed, before everything else.
                let position = losses.first == .metadataEditRequiresReencode(target) ? 1 : 0
                losses.insert(.lossyEncode(target, quality: request.quality.lossyValue), at: position)
            }
            if target == .gif && sourceFormat != .gif {
                losses.append(.paletteLimited)
            }
            if (source.hasAlpha || frame?.background == .transparent) && !target.supportsAlpha {
                losses.append(.transparencyFlattened)
            }
            if source.isAnimated && !target.supportsAnimation {
                losses.append(.animationFirstFrameOnly(frames: source.frameCount))
                frames = 1
            }
            if let depth = source.bitsPerComponent, depth > target.maxBitsPerComponent {
                losses.append(.bitDepthReduced(from: depth, to: target.maxBitsPerComponent))
            }
            if target.requiresRGB, let model = source.colorModel, model != "RGB" {
                losses.append(.colourModelConverted(from: model))
            }
            if source.hasHDRGainMap && !target.supportsGainMap {
                losses.append(.hdrDropped(to: target))
            } else if source.hasHDRGainMap && frame != nil {
                preservesHDR = false
                losses.append(.hdrNotKeptByFit)
            }
            if losses.isEmpty && !sourceFormat.supportsLossless && target.supportsLossless {
                losses.append(.noAdditionalLoss)
            }
            if optimizes && losses.isEmpty {
                info.append(.optimisedLosslessly)
            }
        }
        if strategy == .losslessJPEGTransform { frames = 1 }
        let notes = losses + info + metadataNotes(source, request.metadata)

        return ConversionPlan(
            request: request,
            strategy: strategy,
            verdict: .noReencode,
            notes: notes,
            lossyQuality: lossyQuality,
            losslessAlternative: nil,
            preservesHDR: preservesHDR,
            bakedOrientation: bakedOrientation,
            outputOrientation: outputOrientation,
            pixelCrop: pixelCrop,
            frame: strategy == .reencode ? frame : nil,
            resize: resize,
            displayCrop: displayCrop,
            expectedWidth: outputSize.width,
            expectedHeight: outputSize.height,
            expectedFrameCount: frames
        )
    }

    /// Combining images always creates new pixels: re-encode, upright,
    /// with every scaled input and lost property disclosed.
    private static func compositePlan(
        _ source: MediaInfo, sourceFormat: ImageFormat, request: ConvertRequest, composition: Composition,
        orientation: Orientation, crop: PixelRect?, frame: Framing?, baseSize croppedSize: PixelSize, resize: PixelSize?
    ) -> ConversionPlan {
        let target = request.target
        var losses: [QualityNote] = []
        var hasTransparency = source.hasAlpha || frame?.background == .transparent
        let extras = composition.extraImages

        let canvas: PixelSize
        switch composition {
        case .layers(let layers):
            canvas = croppedSize
            for layer in layers where layer.isResampled {
                losses.append(.imageResampled(
                    name: layer.image.info.fileName,
                    to: PixelSize(width: Int(layer.width.rounded()), height: Int(layer.height.rounded()))
                ))
            }
        case .arrangement(let arrangement):
            let sizes = arrangement.ordered(base: croppedSize, others: arrangement.images.map(\.info.displaySize))
            let result = ArrangementLayout.layout(sizes, arrangement)
            canvas = result.canvas
            let names = arrangement.ordered(base: source.fileName, others: arrangement.images.map(\.info.fileName))
            for (index, frame) in result.frames.enumerated() where frame.size != sizes[index] {
                losses.append(.imageResampled(name: names[index], to: frame.size))
            }
            // Over a colour background everything ends up opaque. Over a
            // transparent one, see-through inputs and uncovered gaps stay so.
            if arrangement.background == .transparent {
                let covered = result.frames.map { $0.width * $0.height }.reduce(0, +)
                hasTransparency = hasTransparency || extras.contains { $0.info.hasAlpha }
                    || covered < canvas.width * canvas.height
            } else {
                hasTransparency = false
            }
        case .canvas(let page):
            canvas = page.size
            let baseHeight = page.base.width * Double(croppedSize.height) / Double(max(croppedSize.width, 1))
            if page.base.isResampled(native: croppedSize) {
                losses.append(.imageResampled(
                    name: source.fileName, to: PixelSize(width: Int(page.base.width.rounded()), height: Int(baseHeight.rounded()))
                ))
            }
            for layer in page.layers where layer.isResampled {
                losses.append(.imageResampled(
                    name: layer.image.info.fileName,
                    to: PixelSize(width: Int(layer.width.rounded()), height: Int(layer.height.rounded()))
                ))
            }
            // Over a colour everything ends up opaque. Over nothing, only an
            // opaque, upright item filling the page hides all of it.
            if page.background == .transparent {
                let filled = (!hasTransparency && covers(page.base, height: baseHeight, canvas: canvas))
                    || page.layers.contains { !$0.image.info.hasAlpha && covers($0.placement, height: $0.height, canvas: canvas) }
                hasTransparency = !filled
            } else {
                hasTransparency = false
            }
        }

        var lossyQuality: Double?
        let lossyWebP = target == .webp && request.quality != .maximum
        if (!target.supportsLossless && target != .gif) || lossyWebP {
            lossyQuality = request.quality.lossyValue
            losses.insert(.lossyEncode(target, quality: request.quality.lossyValue), at: 0)
        }
        if let resize { losses.append(.resampled(from: canvas, to: resize)) }
        if target == .gif { losses.append(.paletteLimited) }
        if hasTransparency && !target.supportsAlpha { losses.append(.transparencyFlattened) }
        if source.isAnimated { losses.append(.animationFirstFrameOnly(frames: source.frameCount)) }
        let depth = ([source] + extras.map(\.info)).compactMap(\.bitsPerComponent).max() ?? 8
        if depth > target.maxBitsPerComponent {
            losses.append(.bitDepthReduced(from: depth, to: target.maxBitsPerComponent))
        }
        if source.hasHDRGainMap || extras.contains(where: { $0.info.hasHDRGainMap }) {
            losses.append(.hdrNotKeptInComposite)
        }
        let output = resize ?? canvas
        let framed: [QualityNote] = frame.map { [.framed(to: croppedSize, background: $0.background)] } ?? []
        let combined: QualityNote = if case .canvas = composition {
            .placedOnCanvas(canvas, images: extras.count)
        } else {
            .composited(images: extras.count)
        }
        return ConversionPlan(
            request: request,
            strategy: .reencode,
            verdict: .noReencode,
            notes: losses + framed + [combined] + metadataNotes(source, request.metadata),
            lossyQuality: lossyQuality,
            losslessAlternative: nil,
            preservesHDR: false,
            bakedOrientation: orientation.exif,
            outputOrientation: 1,
            pixelCrop: crop,
            frame: frame,
            resize: resize,
            displayCrop: crop,
            expectedWidth: output.width,
            expectedHeight: output.height,
            expectedFrameCount: 1
        )
    }

    /// Whether a placement fills the whole canvas with nothing see-through.
    private static func covers(_ placement: LayerPlacement, height: Double, canvas: PixelSize) -> Bool {
        guard placement.opacity >= 1, placement.rotation.truncatingRemainder(dividingBy: 180) == 0 else { return false }
        return placement.centerX - placement.width / 2 <= 0 && placement.centerX + placement.width / 2 >= Double(canvas.width)
            && placement.centerY - height / 2 <= 0 && placement.centerY + height / 2 >= Double(canvas.height)
    }

    /// Moves a crop's top-left corner back onto the JPEG block grid, keeping
    /// its bottom-right corner, as libjpeg-turbo's lossless crop requires.
    static func snapped(_ rect: PixelRect, to block: PixelSize, within size: PixelSize) -> PixelRect {
        let x = rect.x - rect.x % block.width
        let y = rect.y - rect.y % block.height
        let snapped = PixelRect(x: x, y: y, width: rect.maxX - x, height: rect.maxY - y)
        return snapped.clamped(to: size) ?? snapped
    }

    private static func metadataNotes(_ source: MediaInfo, _ policy: MetadataPolicy) -> [QualityNote] {
        switch policy {
        case .keepAll: []
        case .removeLocation: source.hasGPS ? [.locationRemoved] : []
        case .removeAll: [.allMetadataRemoved]
        }
    }
}
