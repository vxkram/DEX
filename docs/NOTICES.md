# Third-party notices

DEX ships the following third-party code. The full licence texts sit next to the vendored sources. They are bundled in `App/Resources/Licenses/` and shown in the app's About window (DEX ▸ About DEX); the vendor scripts keep them in sync.

| Component | Version | Licence | Where |
|---|---|---|---|
| libjpeg-turbo (library + transupp; no tools, no SIMD) | 3.2.0 | IJG License, Modified BSD (3-clause), zlib (`LICENSE.md`, `README.ijg`) | `Packages/DexCore/Sources/CJPEGTurbo/`, vendored by `scripts/vendor-libjpeg-turbo.sh` from the GPG-verified release (SHA-256 `6f30092c…9878e`) |
| LAME (MP3 encoder library only; no frontend, no decoder) | 4.0 | GNU LGPL 2.0 or later (`COPYING`) | `Packages/Lame/Sources/CLame/`, vendored unmodified by `scripts/vendor-lame.sh` from the SourceForge release (SHA-256 `3df5124d…216eb`). Built as its own dynamic library and shipped as `Lame.framework` inside the app, never linked into DEX's binary (ADR 0005) |
| libwebp (encoder and muxer) | 1.6.0 | BSD-3-Clause, plus a patent grant from Google (`PATENTS`) | `Packages/DexCore/Sources/CWebP/`, vendored by `scripts/vendor-libwebp.sh` from the signature-verified release tarball (SHA-256 `e4ab7009…c4564`) |

**Downloaded on first use, not shipped:**
- yt-dlp (Unlicense, public domain), fetched by the Downloader service from github.com/yt-dlp/yt-dlp releases when you first use Download from Link (ADR 0006).
- Enhance models, fetched from the `models-1` release of vxkram/DEX when you first use Enhance (ADR 0008):
  - Real-ESRGAN `realesr-general-x4v3`, `RealESRGAN_x4plus` and `RealESRGAN_x4plus_anime_6B`, © 2021 Xintao Wang, BSD-3-Clause.
  - GFPGAN v1.4, © 2021 Tencent ARC Lab, Apache-2.0. GFPGAN was trained on the FFHQ dataset, whose images are CC BY-NC-SA 4.0. Whether that limits the weights is unsettled, so Faces is off by default.

  The models were converted to Core ML by `scripts/models/build.py`.

**Required attribution** (IJG licence), shown in the About window: *"This software is based in part on the work of the Independent JPEG Group."*

Everything else uses Apple system frameworks (ImageIO, Core Graphics, Accelerate, PDFKit, AVFoundation, AudioToolbox, SwiftUI).
