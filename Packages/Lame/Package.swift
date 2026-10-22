// swift-tools-version: 6.2
import PackageDescription

// LAME (LGPL-2.0-or-later), vendored by scripts/vendor-lame.sh. Its own
// package with a dynamic product, so the app ships it as a separate,
// replaceable library instead of linking it into DEX's binary.
let package = Package(
    name: "Lame",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Lame", type: .dynamic, targets: ["CLame"]),
    ],
    targets: [
        .target(
            name: "CLame",
            exclude: ["COPYING", "LICENSE", "VERSION"],
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("."),
                // Upstream code, compiled as released.
                .unsafeFlags(["-w"]),
            ]
        ),
    ]
)
