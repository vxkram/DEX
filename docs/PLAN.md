# DEX — Product & Architecture Plan (v1: Images)

## Context
`/Users/vikram/DEX` contains only `my_idea.md`: a brief for a macOS-first "media Swiss Army knife" (drop file → choose action → adjust → preview → export) with a strict quality-preservation philosophy. No code exists yet. This plan answers the 15 deliverables in the brief, using the answers from our Q&A and verified research.

**Decisions already made with you**
- Personal tool first; distribution undecided → plan conservatively (sandbox-ready, no GPL, no patent-encumbered encoders of our own).
- Windows/Linux: nice-to-have, years away → Mac-native UI; keep the operation model portable.
- Stack: "best stack that makes the app small and useful". You can learn Swift.
- **Images first.** MVP formats: JPEG, PNG, HEIC/HEIF, WebP, AVIF, TIFF, GIF (incl. animated).
- MVP operations: convert, resize, crop, rotate/flip, compress, **image overlay (watermark/logo)**, **Images ↔ PDF**. Batch UI and text overlay come later.
- Export from the app always goes through a **Save dialog**.
- Metadata: **strip GPS by default**; keep other EXIF, ICC profile and HDR.
- Finder integration: **right-click → quick convert submenu + "Open in DEX"** now; a Finder popup (Action Extension) later.
- Minimum OS: **macOS 26+**.
- **Lossless-first is a hard product rule.**
  - Never re-encode when a lossless path exists.
  - When re-encoding is unavoidable, tell the user *before* export and default to the highest appropriate quality.
  - As a result, **libjpeg-turbo is in the MVP**.
- Compress uses a slider plus a live size estimate. Finder quick convert writes next to the original; the asymmetry with the app's Save dialog is accepted.
- Source control: git plus a private GitHub repo from Phase 0 (`gh` is already logged in). DMG, notarization and the Apple Developer Program come last.

**Machine facts (checked)**
- M4 Pro, 24 GB RAM, macOS 27.0, Swift 6.4.
- **Only Command Line Tools are installed. Full Xcode is required** for the app bundle, extensions, signing and entitlements.
- Homebrew `ffmpeg` 8.1.2 is currently broken: `libx265.216.dylib` is missing. This is exactly why DEX must never depend on a system FFmpeg.

---

## 1. Product definition

**MVP (v1.0: Images + PDF)**
| Area | Included |
|---|---|
| Input | Drag and drop onto the window or Dock icon, Open panel, Finder right-click, paste from clipboard |
| Formats | Read/write JPEG, PNG, HEIC, TIFF, GIF (animated), AVIF*, WebP (write via libwebp) |
| Operations | Convert · Resize (px / % / long edge, never silent upscale) · Crop (free / aspect presets) · Rotate 90° / flip · Compress (quality slider plus live size estimate) · Image overlay (one layer: position, scale, opacity) · Images→PDF · PDF→images |
| Quality | **Lossless-first.** A badge on every operation: *No re-encode* / *Lossless* / *Re-encode*. A lossy export requires an explicit pre-export notice listing exactly what changes, and suggests a lossless alternative when one exists |
| Export | Save dialog with a smart default name; never overwrites the source; atomic writes |
| Finder | "DEX ▸ Convert to JPEG / PNG / HEIC / WebP" (writes next to the original) and "Open in DEX" |
| UX | Large preview, keyboard shortcuts, progress plus cancel, readable errors, Recents list |

\*AVIF encoding: **verified** writable via ImageIO on macOS 26.6.2 (CI) and 27.0 (local), so no libavif is needed. The runtime check stays in place as a safeguard.

**Later (explicitly not in MVP)**
- v1.x: batch UI, presets, text overlay, multiple overlays, Finder Action Extension popup, target-file-size compression, JPEG XL, Sparkle updates.
- v2: video and audio (trim, convert, compress, extract/add audio, overlay).
- v3: compositing (image + audio → video, layered video).

**Challenged assumptions**
- *HEIC was missing from your list.* It is the most common image-conversion source on a Mac, so it's now in the MVP.
- *"It's always lossless" can't be literally true.* Some conversions can't be lossless:
  - HEIC → JPEG, PNG → JPEG, anything → lossy WebP/AVIF, and any resize (resampling creates new pixels).
  - DEX's promise is therefore: **lossless whenever physically possible, never silently lossy, and the highest quality when not.**
  - Where a lossless alternative exists, the app offers it, e.g. "Save as PNG/TIFF instead (lossless, larger)".
- *Compress* has two modes:
  - **Lossless compress**, the default: JPEG Huffman optimisation plus progressive encoding via libjpeg-turbo, lossless WebP, PNG re-encode, and optional metadata stripping.
  - **Smaller file (lossy)**: a quality slider with a live size estimate, which triggers the pre-export notice.
- *Rotating or flipping a JPEG* uses libjpeg-turbo's lossless DCT-domain transform, which actually rotates the pixels, rather than tag-only rotation that some uploaders ignore.
  - If the dimensions aren't MCU-aligned, trim the partial edge block (≤15 px, shown to the user) or fall back to a tag-only rotation. VERIFY which default feels best.
- *Cropping a JPEG* is lossless by default: the crop origin snaps to an 8/16 px block boundary and the handles visibly snap.
  - "Exact pixels" is an opt-in, labelled as a re-encode.
- *"Add image" to images* ships as a watermark/logo overlay only, not a layer editor.

## 2. User flows (MVP)
1. **Convert.** Drop a file. The preview and an info strip (format, size, dimensions, colour profile, HDR, alpha, frames) appear. Click **Convert** and pick a format chip. A quality badge updates live, with a quality slider for lossy formats. Press ⌘E; the Save dialog opens pre-filled with `name.webp`. A progress bar runs, then a "Show in Finder" toast.
2. **Resize.** Choose W×H with an aspect lock, a percentage, or long-edge presets (1080 / 2048 / 4K). Upscaling needs an explicit toggle. Preview, then export.
3. **Crop.** Drag handles over the preview, pick aspect presets (Free, 1:1, 4:5, 16:9, Original), and type exact pixel values. For JPEG, handles snap to lossless block boundaries by default ("Lossless" badge); holding ⌥ unlocks exact pixels ("Re-encode" badge). Enter applies. Rotate/flip live in the same panel.
4. **Compress.** The default is **Lossless** (shows the size saved). Switching to **Smaller file** reveals a quality slider with estimated size versus the original and a split-compare preview at 100% zoom.
10. **Lossy export gate (every flow).** If the verdict is `.lossy`, ⌘E first shows an inline sheet: *"This export re-encodes: HEIC → JPEG at quality 95. HDR → SDR. [Export] [Save as lossless PNG instead]"*. "Don't ask again for this format pair" is available as a per-user setting.
5. **Overlay.** Drop a second image, or choose "Add image…". Drag it into place, use a corner-snapping grid, and set scale and opacity. Export composites at full resolution.
6. **Images → PDF.** Drop several images, reorder the thumbnails, pick page size (Fit image / A4 / Letter) and margin, then export the PDF.
7. **PDF → images.** Drop a PDF, select pages (all by default), choose DPI (72 / 150 / 300) and format, then pick a folder once.
8. **Finder quick convert.** Right-click images, choose DEX ▸ Convert to WebP, and files appear next to the originals as `name.webp` (renamed ` 2` on a name collision). The first use asks for folder permission once.
9. **Finder open.** Right-click, choose DEX ▸ Open in DEX, and the app opens with the file loaded.

## 3. Architecture options

| | Swift + SwiftUI/AppKit | Tauri (Rust + web UI) | Electron |
|---|---|---|---|
| Bundle size | ~5–10 MB (+libwebp ≈ <1 MB) | ~5–15 MB (+ media libs) | 120–200 MB |
| Idle RAM | ~30–60 MB (VERIFY by measuring) | 30–80 MB (+WebKit helpers) | 150–300 MB |
| Media access | Direct ImageIO/Core Image/AVFoundation/VideoToolbox/PDFKit, zero-copy GPU | Needs Rust↔ObjC bridging for Apple frameworks, or FFmpeg for everything | Same as Tauri but heavier |
| macOS feel | Native: Finder extensions, Services, Quick Look, Save panels, menus | Webview UI; extensions still need Swift | Webview UI |
| Dev speed for you | Learning curve (Swift) | Uses your React skills | Uses your React skills |
| Portability | UI is Mac-only | Best | Good |
| Licensing | Apple frameworks are free and include licensed codecs | You ship your own codecs (license and patent exposure) | Same |

**Recommendation: Swift 6 + SwiftUI, with AppKit where SwiftUI is weak** (Save/Open panels, the high-performance zoomable preview, drag-out). Your goals are "small, useful, native". Finder extensions must be Swift regardless, and the Apple frameworks already provide HEIC/AVIF/HDR, colour management and GPU processing for free. A Tauri app would still need Swift or ObjC for every framework we want, so it adds a bridge and saves you nothing. Portability is protected by keeping the operation model pure Swift, not by picking a web UI now.

## 4. Media engine

**The rule: Apple frameworks first. Add a third-party library only when Apple can't do the job.**

| Job | Engine | Why |
|---|---|---|
| Decode all image formats, metadata, thumbnails | **ImageIO** (`CGImageSource`, `CreateThumbnailAtIndex`) | Native, fast, and memory-light when decoding at reduced size |
| Encode JPEG/PNG/HEIC/TIFF/GIF/AVIF | **ImageIO** (`CGImageDestination`) | Native; the writable-format list is checked at runtime via `CGImageDestinationCopyTypeIdentifiers()` |
| Encode WebP (lossless by default when the source is lossless) | **libwebp** (BSD-3), vendored as an SPM C target | ImageIO can't write WebP (confirmed on macOS 27). ~few hundred KB. Only lossy/lossless/alpha/animation encode APIs |
| Crop / resize / rotate / composite | **Core Image** (`CILanczosScaleTransform`, `CISourceOverCompositing`), GPU/Metal-backed, tiled | Handles 100 MP images without full-buffer RAM spikes; colour-managed |
| Metadata-only operations (orientation tag, GPS strip without re-encode) | **ImageIO** `CGImageDestinationCopyImageSource` | True no-re-encode path (JPEG; HEIC support **VERIFY**, per an old rdar) |
| **Lossless JPEG crop / rotate / flip / optimise** | **libjpeg-turbo** (`transupp.c` + libjpeg, linked as an SPM C target, not the CLI; IJG/BSD/zlib licences, attribution required) | DCT-domain transforms mean zero generation loss. The crop origin snaps to the iMCU (8/16 px); `-perfect` rotation needs MCU-aligned dimensions, otherwise trim. Huffman optimisation shrinks files losslessly |
| HDR gain maps | ImageIO aux data (`CGImageSourceCopyAuxiliaryDataInfoAtIndex` / `CGImageDestinationAddAuxiliaryDataInfo`) or the macOS 15+ `kCGImageDestinationEncodeRequest` | Gain maps are **not** carried over automatically; they must be transformed along with crops and resizes |
| PDF | **PDFKit** + `CGContext(url:mediaBox:)` for writing, `CGPDFPage` rendering at DPI/72 for rasterising | Native, no dependencies |
| *(v2)* Video/audio in MOV/MP4/M4A | **AVFoundation + VideoToolbox** (passthrough export, `AVMutableComposition`, `AVAssetReader`/`AVAssetWriter` with hardware encoding) | Hardware-accelerated, uses Apple-licensed H.264/HEVC/AAC encoders |
| *(v2)* WebM/MKV/VP9/AV1/Opus input | **LGPL-only FFmpeg CLI helper**, built by us with `--disable-everything` plus only what's needed, pinned, signed with only the `app-sandbox` and `inherit` entitlements | AVFoundation has no WebM/MKV demuxer. A separate process gives crash isolation and easy LGPL compliance. **No x264/x265** (GPL); encode through `*_videotoolbox`. ffmpeg-kit is retired (Jan 2025), so we don't use it |

**Engine shape (kept small):**
```
protocol MediaOperation      // pure value types: Crop, Resize, Rotate, Overlay, Convert, MetadataPolicy
struct Recipe                 // ordered [MediaOperation] + OutputSpec(format, quality, metadata)
struct ExecutionPlan          // planner output: steps + QualityVerdict + estimated cost
protocol MediaEngine          // func plan(asset, recipe) -> ExecutionPlan; func run(plan, progress) async throws -> URL
ImageEngine: MediaEngine      // v1
PDFEngine: MediaEngine        // v1
AVEngine / FFmpegEngine       // v2
```
There is no plugin system and no generic node graph. One engine per media family, chosen by the asset's type.

## 5. Quality model
The planner is a pure function, `(MediaInfo, Recipe) → ExecutionPlan`, that assigns one verdict:

1. **`.noReencode`**: the coded data is untouched or transformed in the compressed domain.
   - Examples: GPS strip or orientation-tag change, and JPEG lossless crop/rotate/flip/optimise via libjpeg-turbo.
2. **`.lossless`**: pixels are decoded and re-encoded without further loss.
   - Examples: any operation with PNG/TIFF/lossless-WebP output, and cropping a PNG.
   - Lossy → lossless (JPG→PNG) is labelled *"No additional loss; file will be larger."*
3. **`.lossy(reasons)`**: the target codec is lossy and pixels are re-encoded. Each reason is shown to the user:
   - "JPEG re-encode at quality 90"
   - "HDR will be converted to SDR" (when the target can't carry a gain map)
   - "Transparency will be flattened onto white" (alpha → JPEG)
   - "Animation → first frame only" (animated GIF → a still format)
   - "Colour depth 16-bit → 8-bit" (e.g. to JPEG)
   - "Wide colour (P3) will be preserved via ICC"

**Invariants, enforced in the planner and asserted in tests:**
- Output dimensions equal the source unless a resize/crop operation says otherwise; there's never a silent upscale.
- Keep the ICC profile. Keep bit depth when the target supports it. Keep alpha when the target supports it.
- **The planner always searches for a lossless path first.**
  - Order of preference: compressed-domain transform, then lossless codec in the same format, then a lossless target format.
  - It only returns `.lossy` when the user's chosen target or operation forces it. The plan then carries `losslessAlternative: OutputSpec?` for the UI to offer.
- **Default re-encode quality is "Maximum appropriate":** JPEG 0.95 with 4:4:4 chroma where the encoder allows (VERIFY the ImageIO chroma control), HEIC 0.95, WebP lossless if the source is lossless (otherwise q95), AVIF 0.95.
  - Lower values appear only in the "Smaller file" compress mode or in Advanced.
- **Pixel ops go through a float16 Core Image pipeline** so resize, overlay and crop add no banding or rounding beyond the final encode.
- The UI never says "lossless" unless the verdict is `.noReencode` or `.lossless`.

## 6. Project structure
```
DEX/
  DEX.xcodeproj
  App/                        # SwiftUI app target (UI only, no media logic)
    DEXApp.swift, Views/{DropZone, Preview, ActionBar, Inspector, Crop, Overlay, PDF}, Export/, Recents/
  Extensions/
    FinderIntegration/        # right-click submenu target (see §9)
  Packages/DexCore/       # local SwiftPM package; builds & tests with `swift test`, no Xcode needed
    Sources/
      MediaModel/             # Recipe, Operation, MediaInfo, QualityVerdict, Planner (Foundation only → portable)
      ImageEngine/            # ImageIO + Core Image + metadata + HDR
      PDFEngine/              # PDFKit / CoreGraphics
      WebPCodec/ + CWebP/     # vendored libwebp (pinned version, BSD notice)
      JPEGLossless/ + CJPEGTurbo/  # vendored libjpeg-turbo (jpeglib + transupp), pinned
      JobSystem/              # JobQueue actor, progress, cancellation, temp files, atomic output
      dex-cli/            # `dex inspect|convert|resize …` for tests, benchmarks, debugging
    Tests/                    # Swift Testing: unit + integration
  Fixtures/                   # curated media + generator script
  scripts/                    # build, sign, notarize, dmg, fixture generation
  docs/                       # ADRs (architecture decision records), licences/NOTICES
```
Plain Xcode project plus a local package. No XcodeGen or Tuist yet (not needed for a solo developer). The CLI lets the engine be developed and tested before any UI exists.

## 7. Data flow
```
Drop/Finder/Open → App: AssetLoader (security-scoped URL) → ImageEngine.inspect → MediaInfo → UI (preview via thumbnail/CI render)
User adjusts   → UI mutates Recipe (value type) → Planner → ExecutionPlan (verdict badge, size estimate) → live preview (CIImage at view scale, debounced)
Export (⌘E)    → NSSavePanel → JobQueue.submit(plan, dest)
                 → Task { decode → CI pipeline → encode to temp file on same volume → fsync → atomic move to dest }
                 → AsyncStream<Progress> → UI progress/cancel → done: reveal in Finder, add to Recents
Cancel         → Task.cancel(); checked between stages/frames/pages; temp file removed
```

## 8. Performance
- **RAM:** full decodes of huge images (a 100 MP image at 8-bit RGBA is ~400 MB, at 16-bit ~800 MB).
  - Previews always use `CreateThumbnailAtIndex` or down-sampled CI rendering.
  - Export uses tiled Core Image rendering.
  - Only one full-resolution job per ~2 GB of headroom at a time.
- **GPU:** keep a single shared `CIContext` (creating one is expensive). Use a Metal-backed context with an explicit working colour space (extended linear sRGB, float16 for >8-bit sources).
- **CPU:** WebP, AVIF and HEIC encoding is CPU-heavy (HEIC may use the hardware encoder; VERIFY).
  - Batch and PDF concurrency are bounded to the number of performance cores.
- **Disk I/O:** write temp files to `.itemReplacementDirectory` on the destination volume so the final move is atomic.
  - Stream PDF pages rather than holding them all in memory.
- **UI:** debounce the preview (~50 ms) and never decode on the main actor.
- **Measurement:** `os_signpost` around each stage, plus a `dex-cli bench` command with a fixed corpus. Track the numbers in CI to catch regressions.

## 9. macOS specifics
- **App Sandbox on from day one.** Retrofitting it later is painful, and it keeps the App Store option open.
  - Entitlements: `files.user-selected.read-write` and `files.bookmarks.app-scope` (for Recents).
- **File access:**
  - App exports use `NSSavePanel`, which is sandbox-trivial.
  - Recents use security-scoped bookmarks. Note CVE-2025-31191 and the bookmark bugs in 15.0; test on 26/27.
  - Finder quick convert writes next to the original. That needs a folder grant: a one-time `NSOpenPanel` preselected on the folder, then a bookmark. "Related Items" is fragile, so we avoid it.
- **Finder integration: VERIFY with a spike before committing.**
  - Option A: a **Finder Sync extension**. It gives a real "DEX ▸" submenu, but menus only appear for monitored folders (can be `/`) and the user must enable it in System Settings.
  - Option B: **NSServices** entries. Flat items under Quick Actions/Services, simple and robust.
  - Option C (later): an **Action Extension** popup.
  - Plan: spike A and B in Phase 6, pick one, and record the choice in an ADR.
- **Signing & distribution:**
  - Developer ID plus hardened runtime, `notarytool submit --wait`, `stapler staple` on the DMG, built with the `create-dmg` shell script.
  - An Apple Developer Program membership (paid, yearly) is needed for notarization. Until then, local development signing works on your own Mac.
- **Apple Silicon only (arm64).** Intel isn't worth the cost for a macOS 26+ app; macOS 26 is reportedly the last Intel-supporting release (VERIFY).
- **Integration:** Dock-icon drop, document types in Info.plist (so "Open With" works), the Services menu, and a Quick Look–style preview.

## 10. Security
- **Malformed and hostile files:** decoders (ImageIO, libwebp, PDFKit) are the attack surface.
  - Keep libwebp pinned and updated. Remember the 2023 libwebp heap overflow, CVE-2023-4863.
  - The sandbox limits the damage.
  - Clamp limits before decoding: maximum pixel count (e.g. 500 MP), maximum frames and maximum pages. Reject with a clear error.
- **Paths:**
  - Never build shell strings; use `URL` and `FileManager` only.
  - Sanitise output names (strip `/`, `:` and control characters, keep Unicode).
  - Resolve and deny output that equals the source (compare file resource identifiers, not path strings).
  - Handle iCloud placeholders (`.icloud` files) and read-only volumes gracefully.
- **Temp files:** use per-job temp directories, removed on success, failure or cancel. Sweep leftovers at launch.
- **Metadata privacy:** GPS is stripped by default. Tell the user when location data was removed.
- **Subprocesses (v2 FFmpeg):** use `Process` with an argument array (never a shell), a fixed bundled binary path, and an allowlisted argument builder. Kill it on cancel and on app quit.
- **PDF:** don't execute JavaScript and don't follow links. Handle encrypted PDFs with a password prompt.

## 11. Testing
- **Framework:** Swift Testing (`@Test`) in `DexCore`, run via `swift test`. UI smoke tests use XCUITest later.
- **Unit tests** (pure and fast):
  - Planner verdicts for every source × target × operation combination; the matrix is table-driven.
  - Output naming and collisions.
  - Recipe validation.
- **Integration tests:** real encode/decode against the fixture corpus. Each test asserts:
  - Dimensions and orientation are correct for EXIF orientations 1–8.
  - Colour space and ICC are preserved.
  - Bit depth and alpha are handled correctly.
  - GPS is present or absent as expected.
  - Frame count is correct for GIF.
  - PSNR/SSIM is above a threshold against a reference for lossy output, and pixels match exactly for lossless output.
  - **The source file's hash is unchanged.**
- **Fixture corpus** (`Fixtures/`):
  - Generated by a script: sizes, alpha, 8/16-bit, sRGB/P3/Gray/CMYK, orientations.
  - Curated real-world files: iPhone HEIC with HDR gain map, progressive JPEG, CMYK JPEG, animated GIF, AVIF, lossless and lossy WebP, a 100 MP TIFF, a multi-page PDF, an encrypted PDF.
- **Edge and hostile cases:**
  - Zero-byte, truncated and wrong-extension files.
  - Fuzzed files (mutated bytes; they must fail gracefully, never crash).
  - A 1×1 image and extreme aspect ratios (1×20000).
  - Unicode, emoji, spaces and very long paths.
  - Read-only destinations and a full disk (simulated).
  - Cancel mid-job (asserts no partial output and no temp leftovers).
- **Performance tests:** a benchmark corpus with fixed budgets, e.g. 24 MP HEIC → JPEG in under X ms on M4 Pro (baseline set in Phase 1).
- **CI:** GitHub Actions on a macOS runner runs `swift test` and `xcodebuild test` (VERIFY that a macos-26 runner image is available).

## 12. Development phases
Each phase ends with the app or CLI usable, tests green, and an ADR for any decision made.

**Phase 0: Foundations** (≈2–3 days)
- *Goal:* a reproducible environment.
- *Work:*
  - Install Xcode and `git init`.
  - Create the `DexCore` package with `MediaModel` + `dex-cli`, plus an empty SwiftUI app target linked to the package.
  - Write the fixture generator, a Makefile/`scripts/`, and CI running `swift test`.
- *Tests:* one sanity test and a CLI smoke test.
- *Done when:* `swift test` and `xcodebuild` both pass from a clean clone.

**Phase 1: Inspect + Convert engine (CLI)**
- *Goal:* correct, quality-preserving conversion.
- *Features:*
  - `dex inspect` (format, dimensions, depth, colour, alpha, HDR, frames, metadata).
  - `dex convert` for all MVP formats, with the metadata policy (GPS strip) and verdicts.
- *Work:*
  - ImageIO read/write and the runtime writable-type check.
  - libwebp and libjpeg-turbo vendored (build from source via SPM C targets; SIMD asm may need CMake-generated config headers, VERIFY).
  - Planner v1 and the JobQueue with progress, cancellation and atomic output.
- *Tests:* the full verdict matrix, the conversion integration matrix, the source-unchanged check, cancellation.
- *Done when:* a matrix report shows every source→target pair either passing or explicitly marked unsupported.

**Phase 2: Transforms (CLI)**
- *Features:* resize (Lanczos), crop (lossless JPEG block-snapped plus exact), rotate/flip (lossless JPEG transform), compress (lossless mode plus lossy slider with size estimate), animated GIF frame preservation, HDR gain-map carry-through, and the lossy export gate data (reasons plus lossless alternative).
- *Tests:* dimension and orientation invariants, **bit-exact DCT coefficient comparison for lossless JPEG ops** (decode source crop vs output: identical pixels), SSIM thresholds for lossy output, gain map present after crop and resize, a 100 MP memory ceiling test.
- *Done when:* every operation is reachable from the CLI with benchmark numbers recorded.

**Phase 3: App shell**
- *Features:* drop zone, large preview, info strip, action bar, inspector panel, convert/resize/rotate/compress UI, quality badge, Save panel export, progress + cancel, error presentation, Recents, keyboard shortcuts.
- *Tests:* view-model unit tests and an XCUITest smoke run (drop → convert → export).
- *Done when:* you'd use it daily for HEIC→JPG and resize work.

**Phase 4: Crop + Overlay UI**
- *Features:* interactive crop with aspect presets; a single image overlay (drag, scale, opacity, snapping).
- *Tests:* geometry math unit tests (view ↔ pixel space); exported overlay pixel-placement tests.

**Phase 5: PDF**
- *Features:* Images→PDF (reorder, page size, margins); PDF→images (pages, DPI, format); encrypted PDF prompt.
- *Tests:* page count, sizes and DPI accuracy; a large-PDF streaming memory test.

**Phase 6: Finder integration**
- *Work:*
  - A spike comparing Finder Sync and Services, then build the chosen one.
  - Quick convert with a one-time folder grant, and "Open in DEX".
- *Tests:* manual test script plus an integration test of the shared conversion entry point.
- *Done when:* right-click → Convert to WebP works on 10 selected files in a new folder.

**Phase 7: Polish & ship**
- *Work:* app icon and visual identity pass, empty/error states, performance pass, signing, notarization, DMG, licences/NOTICES (libwebp, libjpeg-turbo IJG attribution), and a README.
- *Done when:* a notarized DMG installs and runs on a clean macOS 26 user account.

**After v1:** batch UI, presets, then the Action Extension popup, then v2 video/audio (AVFoundation first, then the FFmpeg LGPL helper).

## 13. Risks
- **Technical:**
  - HDR gain-map handling is fragile (silent loss, iOS 26 Finalize bug reports).
  - AVIF encoding may be unavailable on macOS 26.
  - `CopyImageSource` may not support HEIC.
  - Finder context-menu APIs are limited (Finder Sync requires the user to enable it).
  - Core Image colour-management mistakes can cause subtle colour shifts, which is why pixel/ICC tests exist.
  - libwebp security updates are our responsibility.
  - The sandbox makes "write next to the original" awkward.
  - Swift learning curve.
- **Product:**
  - Scope creep into video before images are polished.
  - "Compress" expectations: users want a target size, not a slider.
  - A macOS 26+ minimum limits the audience (fine for a personal tool).
  - It competes with free built-ins (Preview, Finder's Quick Action "Convert Image", `sips`). **The differentiator must be speed, quality honesty and polish, not features.**

## 14. Future extensibility
- **More formats and codecs:** add an encoder/decoder behind `ImageEngine`'s codec table. The planner learns each format's capabilities (alpha, depth, HDR, animation, lossless) from a single `FormatCapabilities` table.
- **Batch and presets:** a `Recipe` is already a serialisable value (Codable). Batch means one recipe applied to N assets through the JobQueue; a preset is a saved recipe.
- **Plugins:** not planned. If ever needed, they would be out-of-process XPC services taking a Recipe, not dynamic code loading.
- **Video and audio:** the same `MediaEngine` protocol, implemented by `AVEngine` and an FFmpeg helper; the quality model gains stream-copy/remux verdicts.
- **Windows and Linux:** `MediaModel` (recipes, planner, quality rules) is Foundation-only Swift. It could run on Swift for Windows/Linux, or serve as the spec for a port. The engines would be rewritten on FFmpeg/libvips, and the UI would be new. That's honest: a port is a new front end plus new engines, reusing the model and tests.
- **Advanced editing:** multiple overlays and text become a `Layers` operation list inside a Recipe. A timeline is only justified if v3 compositing demands it.

## 15. First implementation task
**Phase 0 plus the start of Phase 1: `dex inspect`.**
1. Install Xcode (App Store) and run `sudo xcode-select -s /Applications/Xcode.app`.
   - `git init`, add `.gitignore` (Xcode/SwiftPM), `README.md` and `docs/adr/0001-stack.md`.
   - Keep `my_idea.md` and this plan in `docs/`.
   - Create a **private** GitHub repo with `gh repo create DEX --private --source . --push`.
2. Create `Packages/DexCore` with targets `MediaModel`, `ImageEngine` and `dex-cli`, plus a test target.
3. Implement `MediaInfo` and `ImageEngine.inspect(url:) async throws -> MediaInfo` (UTType, pixel dimensions after orientation, bit depth, colour model and profile name, alpha, HDR gain map present, frame count, has GPS) using `CGImageSource` only.
4. Add `dex inspect <file> [--json]`.
5. Write a fixture generator script plus tests covering JPEG/PNG/HEIC/TIFF/GIF/WebP/AVIF inspection, the EXIF orientations, and a truncated file.
6. Print `CGImageDestinationCopyTypeIdentifiers()` as `dex formats`. This settles the AVIF/WebP writability question on your machine.

It's small, UI-free, fully testable, and every later feature depends on it.

## Verification (for the plan as a whole)
- `swift test` in `Packages/DexCore` is green at every phase.
- `dex formats` and `dex inspect` run against the `Fixtures/` corpus.
- From Phase 3: build and run the app via Xcode, then drop test files and export.
- From Phase 7: `spctl -a -vv` and `stapler validate` on the DMG.

## Decisions made in the final round
- The Developer Program and DMG are deferred. Git plus a private GitHub repo come first.
- libjpeg-turbo is in the MVP, and lossless-first is a product rule (see §1, §5).
- Compress: slider plus size estimate, with lossless mode as the default.
- Finder writes next to the original; the app uses a Save dialog.

## Remaining open items (decide during the build, not now)
- JPEG rotation when dimensions aren't MCU-aligned: trim ≤15 px or use a tag-only rotation? Try both in Phase 2.
- Finder Sync vs Services: decided by the Phase 6 spike.
