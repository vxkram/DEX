# ADR 0007: DEX for Windows

Date: 2026-10-20 · Status: accepted

## Decision
- **One repo, two apps.** `mac/` is the existing SwiftUI app, unchanged. `windows/` is a new app built from scratch. Shared things stay at the root: `design/` (icon master, screenshots), `docs/`, `LICENSE`, CI.
- **Stack: Tauri 2 (Rust) + React + TypeScript.** The same split as the Mac app: `windows/src/` is UI only (like `App/`), and `windows/src-tauri/` holds the engines as Tauri commands (like `DexCore`). It's a small native installer (WebView2 is built into Windows 10/11), there's no Node at runtime, and the Rust side can call the same C libraries DEX already ships.
- **The rules carry over, not the code.** Lossless first, never silently lossy, the real output size before saving, the original never overwritten (temp file + atomic rename), and location data removed by default. The planner (`MediaModel`: No re-encode / Lossless / Lossy verdicts and notes) gets ported to Rust first, with its tests, so every tool asks it before encoding.

## What replaces each Apple framework

| Mac (Apple) | Windows |
|---|---|
| SwiftUI / AppKit | React in Tauri's WebView2 window |
| ImageIO decode/encode | `image` crate (PNG, JPEG, GIF, TIFF, WebP), `libheif-rs` (HEIC, AVIF) |
| Lossless JPEG crop/rotate (libjpeg-turbo) | Same library, via `turbojpeg` (`tjTransform`) |
| WebP (vendored libwebp) | Same library, via `webp` / `libwebp-sys` |
| HDR (gain maps, ImageIO) | libheif reads the HDR planes; keeping HDR across formats is its own milestone |
| Metadata / GPS stripping | `little_exif` / `kamadak-exif` |
| PDFKit | `lopdf` (rearrange, rotate, delete, merge, split, with no re-encoding), `pdfium-render` + `pdfium.dll` (render pages to images) |
| AVFoundation / AudioToolbox | Bundled `ffmpeg.exe` (LGPL build) as a sidecar: decode, encode, stream copy |
| MP3/AAC trim without re-encoding | `ffmpeg -c copy` cuts on frame boundaries; sample-exact trims need the encoder delay/padding handling ported from `AudioEngine` |
| LAME (MP3) | ffmpeg's libmp3lame (LGPL, in the same sidecar) |
| Accelerate (waveform) | Rust: decode with ffmpeg to PCM, peaks computed in Rust |
| Tags and cover art | `lofty` |
| yt-dlp in an XPC service | `yt-dlp.exe` from the official release, verified against `SHA2-256SUMS`, in `%LOCALAPPDATA%\DEX\Tools`, run as a child process with a fixed argument array (never a shell) |
| Video mux (`VideoMuxer`) | `ffmpeg -c copy` (it also fixes the doubled-length headers) |
| Finder Services | Explorer right-click entries, written by the installer |

## Order
1. Shell: drop zone, file open, tool dock (Convert / Crop / Compress / Compose / PDF / Info). **← started**
2. Port the planner and its tests to Rust.
3. Image Convert and Compress, then Crop (lossless JPEG first), then Compose.
4. PDF.
5. Audio: trim, convert, tags, waveform.
6. Download from Link.
7. Explorer context menu, signing.

## Not decided yet
- Code signing (unsigned installers trigger SmartScreen, the Windows version of the Gatekeeper prompt).
- Whether ARM64 Windows builds ship alongside x64.
