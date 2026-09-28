# ADR 0001: Native Swift, Apple frameworks first

Date: 2026-09-29 · Status: accepted

## Decision
- **App:** Swift 6 + SwiftUI, with AppKit where SwiftUI falls short. Minimum macOS 26, Apple Silicon only.
- **Media:** ImageIO, Core Image, PDFKit and (for v2) AVFoundation/VideoToolbox first.
- **Third-party code, only where Apple can't do the job:**
  - libwebp (ImageIO can't encode WebP).
  - libjpeg-turbo (lossless JPEG crop/rotate/optimise).
  - For v2, an LGPL-only FFmpeg CLI helper for WebM/MKV.
- **Engine:** lives in the `DexCore` SwiftPM package, fully testable without the UI.

## Why
- **Small and light:** a native app is ~5–10 MB and ~30–60 MB idle RAM (to be measured), versus 120–200 MB for Electron.
- **Codecs for free:** Apple frameworks provide HEIC/AVIF/HDR decoding, colour management, GPU processing and licensed H.264/HEVC/AAC encoders at no size or licence cost.
- **Finder integration** must be Swift regardless.
- **Tauri would not save work:** it would still need Swift/ObjC bridging for every Apple framework.

## Consequences
- The UI isn't portable. For portability, `MediaModel` stays Foundation-only; a future Windows/Linux port reuses the model and tests and replaces the engines and UI.
- **Verified 2026-09-29 on macOS 27.0 (`dex formats`):** ImageIO writes JPEG, PNG, HEIC, AVIF, TIFF and GIF. It does not write WebP or `public.heif`. CI on macOS 26.6.2 (Xcode 26.6) reports the same, so AVIF encoding is native on the whole supported range and libavif is not needed.
