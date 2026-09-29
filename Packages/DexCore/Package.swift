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
        // libjpeg-turbo 3.2.0 (IJG + BSD-3 + zlib), vendored by
        // scripts/vendor-libjpeg-turbo.sh, for lossless JPEG crops and
        // optimisation. Base files compiled through the 8/12/16-bit wrappers,
        // and fragments other files #include, are excluded here.
        .target(
            name: "CJPEGTurbo",
            exclude: [
                "LICENSE.md",
                "README.ijg",
                "VERSION",
                "libjpeg/jcapistd.c",
                "libjpeg/jccoefct.c",
                "libjpeg/jccolor.c",
                "libjpeg/jcdctmgr.c",
                "libjpeg/jcdiffct.c",
                "libjpeg/jclossls.c",
                "libjpeg/jcmainct.c",
                "libjpeg/jcprepct.c",
                "libjpeg/jcsample.c",
                "libjpeg/jdapistd.c",
                "libjpeg/jdcoefct.c",
                "libjpeg/jdcolor.c",
                "libjpeg/jddctmgr.c",
                "libjpeg/jddiffct.c",
                "libjpeg/jdlossls.c",
                "libjpeg/jdmainct.c",
                "libjpeg/jdmerge.c",
                "libjpeg/jdpostct.c",
                "libjpeg/jdsample.c",
                "libjpeg/jfdctfst.c",
                "libjpeg/jfdctint.c",
                "libjpeg/jidctflt.c",
                "libjpeg/jidctfst.c",
                "libjpeg/jidctint.c",
                "libjpeg/jidctred.c",
                "libjpeg/jquant1.c",
                "libjpeg/jquant2.c",
                "libjpeg/jutils.c",
                "libjpeg/jccolext.c",
                "libjpeg/jdcol565.c",
                "libjpeg/jdcolext.c",
                "libjpeg/jdmrg565.c",
                "libjpeg/jdmrgext.c",
                "libjpeg/jstdhuff.c",
            ],
            cSettings: [
                .headerSearchPath("libjpeg"),
                .headerSearchPath("config"),
                // Upstream's JLONG→int conversions in pixel paths DEX
                // doesn't use; silenced only for this vendored target.
                .unsafeFlags(["-Wno-shorten-64-to-32"]),
            ]
        ),
        // ImageIO / Core Image backed processing.
        .target(name: "ImageEngine", dependencies: ["MediaModel", "JobSystem", "CWebP", "CJPEGTurbo"]),
        .executableTarget(name: "dex-cli", dependencies: ["MediaModel", "ImageEngine", "JobSystem"]),
        .testTarget(name: "MediaModelTests", dependencies: ["MediaModel"]),
        .testTarget(name: "JobSystemTests", dependencies: ["JobSystem"]),
        .testTarget(name: "ImageEngineTests", dependencies: ["ImageEngine", "MediaModel", "JobSystem"]),
    ]
)
