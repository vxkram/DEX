// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DexCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MediaModel", targets: ["MediaModel"]),
        .library(name: "ImageEngine", targets: ["ImageEngine"]),
        .executable(name: "dex", targets: ["dex-cli"]),
    ],
    targets: [
        // Pure value types and quality rules. Foundation only, so it stays portable.
        .target(name: "MediaModel"),
        // ImageIO / Core Image backed processing.
        .target(name: "ImageEngine", dependencies: ["MediaModel"]),
        .executableTarget(name: "dex-cli", dependencies: ["MediaModel", "ImageEngine"]),
        .testTarget(name: "MediaModelTests", dependencies: ["MediaModel"]),
        .testTarget(name: "ImageEngineTests", dependencies: ["ImageEngine", "MediaModel"]),
    ]
)
