import Foundation

/// Everything DEX learns about a media file before any operation is planned.
public struct MediaInfo: Codable, Sendable, Equatable {
    public var fileName: String
    public var fileSize: Int64
    /// The container type reported by the decoder, e.g. `public.heic`.
    public var typeIdentifier: String
    /// `nil` when the file decodes but is not a format DEX can target.
    public var format: ImageFormat?

    /// Stored pixel dimensions, before EXIF orientation is applied.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// EXIF orientation, 1–8. 1 means "as stored".
    public var orientation: Int

    public var bitsPerComponent: Int?
    /// ImageIO colour model, e.g. `RGB`, `Gray`, `CMYK`.
    public var colorModel: String?
    /// Embedded ICC profile description, e.g. `Display P3`.
    public var colorProfile: String?
    public var hasAlpha: Bool
    public var hasHDRGainMap: Bool
    public var frameCount: Int
    public var hasGPS: Bool

    public init(
        fileName: String,
        fileSize: Int64,
        typeIdentifier: String,
        format: ImageFormat?,
        pixelWidth: Int,
        pixelHeight: Int,
        orientation: Int = 1,
        bitsPerComponent: Int? = nil,
        colorModel: String? = nil,
        colorProfile: String? = nil,
        hasAlpha: Bool = false,
        hasHDRGainMap: Bool = false,
        frameCount: Int = 1,
        hasGPS: Bool = false
    ) {
        self.fileName = fileName
        self.fileSize = fileSize
        self.typeIdentifier = typeIdentifier
        self.format = format
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.orientation = orientation
        self.bitsPerComponent = bitsPerComponent
        self.colorModel = colorModel
        self.colorProfile = colorProfile
        self.hasAlpha = hasAlpha
        self.hasHDRGainMap = hasHDRGainMap
        self.frameCount = frameCount
        self.hasGPS = hasGPS
    }

    /// Orientations 5–8 rotate by 90°, swapping width and height on display.
    public var swapsAxes: Bool { (5...8).contains(orientation) }

    /// Dimensions as the image appears to a viewer.
    public var displayWidth: Int { swapsAxes ? pixelHeight : pixelWidth }
    public var displayHeight: Int { swapsAxes ? pixelWidth : pixelHeight }

    public var isAnimated: Bool { frameCount > 1 }
}
