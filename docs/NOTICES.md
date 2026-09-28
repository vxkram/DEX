# Third-party notices

DEX ships the following third-party code. The full licence texts sit next to the vendored sources and must be included in the app's About/Acknowledgements screen before distribution.

| Component | Version | Licence | Where |
|---|---|---|---|
| libwebp (encoder and muxer) | 1.6.0 | BSD-3-Clause, plus a patent grant from Google (`PATENTS`) | `Packages/DexCore/Sources/CWebP/`, vendored by `scripts/vendor-libwebp.sh` from the signature-verified release tarball (SHA-256 `e4ab7009…c4564`) |

Everything else uses Apple system frameworks (ImageIO, Core Graphics, Accelerate, SwiftUI).
