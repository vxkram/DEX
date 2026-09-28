// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DexCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MediaModel", targets: ["MediaModel"]),
        .library(name: "ImageEngine", targets: ["ImageEngine"]),
        .library(name: "JobSystem", targets: ["JobSystem"]),
        .executable(name: "dex", targets: ["dex-cli"]),
    ],
    targets: [
        // Pure value types and quality rules. Foundation only, so it stays portable.
        .target(name: "MediaModel"),
        // Safe output handling: temp files, atomic moves, never touching the source.
        .target(name: "JobSystem"),
        // libwebp 1.6.0 (BSD-3), vendored by scripts/vendor-libwebp.sh. ImageIO
        // can read WebP but not write it.
        .target(
            name: "CWebP",
            exclude: ["COPYING", "PATENTS", "VERSION"],
            cSettings: [.headerSearchPath(".")]
        ),
        // ImageIO / Core Image backed processing.
        .target(name: "ImageEngine", dependencies: ["MediaModel", "JobSystem", "CWebP"]),
        .executableTarget(name: "dex-cli", dependencies: ["MediaModel", "ImageEngine", "JobSystem"]),
        .testTarget(name: "MediaModelTests", dependencies: ["MediaModel"]),
        .testTarget(name: "JobSystemTests", dependencies: ["JobSystem"]),
        .testTarget(name: "ImageEngineTests", dependencies: ["ImageEngine", "MediaModel", "JobSystem"]),
    ]
)
