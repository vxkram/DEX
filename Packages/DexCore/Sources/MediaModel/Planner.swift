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
        plan.verdict = plan.strategy == .reencode
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
        var strategy = ConversionStrategy.reencode
        var losses: [QualityNote] = []

        if sourceFormat == target {
            let changesMetadata = request.metadata == .removeAll
                || (request.metadata == .removeLocation && source.hasGPS)
            if !changesMetadata {
                strategy = .copyFile
            } else if target.supportsLosslessMetadataEdit {
                strategy = .rewriteMetadata
            } else if !target.reencodesLosslessly {
                losses.append(.metadataEditRequiresReencode(target))
            }
        }

        var frames = source.frameCount
        var width = source.pixelWidth
        var height = source.pixelHeight
        var info: [QualityNote] = []
        var appliesOrientation = false
        var lossyQuality: Double?
        if strategy == .reencode {
            if source.orientation != 1 && !target.supportsOrientationTag {
                appliesOrientation = true
                (width, height) = (source.displayWidth, source.displayHeight)
                info.append(.orientationApplied)
            }
            let lossyWebP = target == .webp && request.quality != .maximum
            if (!target.supportsLossless && target != .gif) || lossyWebP {
                lossyQuality = request.quality.lossyValue
                losses.append(.lossyEncode(target, quality: request.quality.lossyValue))
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
        }
        let notes = losses + info + metadataNotes(source, request.metadata)

        return ConversionPlan(
            request: request,
            strategy: strategy,
            verdict: .noReencode,
            notes: notes,
            lossyQuality: lossyQuality,
            losslessAlternative: nil,
            preservesHDR: source.hasHDRGainMap && target.supportsGainMap,
            appliesOrientation: appliesOrientation,
            expectedWidth: width,
            expectedHeight: height,
            expectedFrameCount: frames
        )
    }

    private static func metadataNotes(_ source: MediaInfo, _ policy: MetadataPolicy) -> [QualityNote] {
        switch policy {
        case .keepAll: []
        case .removeLocation: source.hasGPS ? [.locationRemoved] : []
        case .removeAll: [.allMetadataRemoved]
        }
    }
}
