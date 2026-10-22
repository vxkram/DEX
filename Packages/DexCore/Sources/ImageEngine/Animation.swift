import CoreGraphics
import Foundation
import ImageIO
import JobSystem
import MediaModel

/// The frames of an animated GIF or WebP, small, with their timing: what a
/// timeline shows and plays.
public struct AnimationFrames: @unchecked Sendable {
    /// Upright, composited frames (ImageIO applies disposal and blending).
    public let frames: [CGImage]
    /// Display time of each frame, in seconds.
    public let delays: [Double]

    public var duration: Double { delays.reduce(0, +) }

    /// Seconds from the start of `range`'s first frame to the end of its last.
    public func duration(of range: ClosedRange<Int>) -> Double {
        delays[range.clamped(to: 0...max(delays.count - 1, 0))].reduce(0, +)
    }
}

extension ImageEngine {
    /// Timelines stop here; longer animations still convert.
    public static let maxTimelineFrames = 1000

    /// Every frame, decoded small enough that all of them fit in memory
    /// (about 100 megapixels in all), with each frame's delay.
    public static func animationFrames(url: URL, maxPixelSize: Int = 720) async throws -> AnimationFrames {
        try await MediaWork.run { token in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw InspectError.notAnImage(url.lastPathComponent)
            }
            let count = CGImageSourceGetCount(source)
            guard count > 1, count <= maxTimelineFrames else { throw InspectError.corrupt(url.lastPathComponent) }
            let side = min(maxPixelSize, max(Int((100_000_000 / Double(count)).squareRoot()), 64))
            var frames: [CGImage] = []
            var delays: [Double] = []
            for index in 0..<count {
                try token.check()
                let options = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: side,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary
                guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options) else {
                    throw InspectError.corrupt(url.lastPathComponent)
                }
                frames.append(frame)
                delays.append(frameDelay(source, index))
            }
            return AnimationFrames(frames: frames, delays: delays)
        }
    }

    /// The delay the file asks for (unclamped where given), in seconds.
    static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let pairs: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dictionary, unclamped, clamped) in pairs {
            guard let values = properties[dictionary] as? [CFString: Any] else { continue }
            if let delay = (values[unclamped] as? Double) ?? (values[clamped] as? Double), delay > 0 {
                return max(delay, 0.01)
            }
        }
        return 0.1
    }
}
