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
        let resize = geometry.resize.flatMap { $0 == croppedSize || $0.width < 1 || $0.height < 1 ? nil : $0 }
        let changesPixels = crop != nil || resize != nil

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
            } else if target.supportsLosslessMetadataEdit && target.supportsOrientationTag {
                strategy = .rewriteMetadata
                outputOrientation = total.exif
            } else if !target.reencodesLosslessly {
                losses.append(.metadataEditRequiresReencode(target))
            }
        }

        // 2. JPEG crop and/or optimisation on the compressed data: no
        //    decode, no loss.
        if strategy == .reencode, sourceFormat == .jpeg, target == .jpeg, resize == nil, !wantsLossy,
           (crop != nil && !geometry.exactCrop) || (crop == nil && optimizes),
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
                // Work upright: bake the orientation, then crop and resize.
                bakedOrientation = total.exif
                outputOrientation = 1
                pixelCrop = crop
                outputSize = resize ?? croppedSize
                if formatCantRotate && !changesPixels { info.append(.orientationApplied) }
                if let resize { losses.append(.resampled(from: croppedSize, to: resize)) }
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
            if source.hasAlpha && !target.supportsAlpha {
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
            resize: resize,
            displayCrop: displayCrop,
            expectedWidth: outputSize.width,
            expectedHeight: outputSize.height,
            expectedFrameCount: frames
        )
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
