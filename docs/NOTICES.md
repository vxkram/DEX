# Third-party notices

DEX ships the following third-party code. The full licence texts sit next to the vendored sources and must be included in the app's About/Acknowledgements screen before distribution.

| Component | Version | Licence | Where |
|---|---|---|---|
| libjpeg-turbo (library + transupp; no tools, no SIMD) | 3.2.0 | IJG License, Modified BSD (3-clause), zlib (`LICENSE.md`, `README.ijg`) | `Packages/DexCore/Sources/CJPEGTurbo/`, vendored by `scripts/vendor-libjpeg-turbo.sh` from the GPG-verified release (SHA-256 `6f30092c…9878e`) |
| libwebp (encoder and muxer) | 1.6.0 | BSD-3-Clause, plus a patent grant from Google (`PATENTS`) | `Packages/DexCore/Sources/CWebP/`, vendored by `scripts/vendor-libwebp.sh` from the signature-verified release tarball (SHA-256 `e4ab7009…c4564`) |

**Required attribution** (IJG licence), to be shown in the app's About screen: *"This software is based in part on the work of the Independent JPEG Group."*

Everything else uses Apple system frameworks (ImageIO, Core Graphics, Accelerate, SwiftUI).
