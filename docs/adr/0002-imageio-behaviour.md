# ADR 0002: Measured ImageIO behaviour and how DEX handles it

Date: 2026-09-29 · Status: accepted · Measured on macOS 27.0 (Xcode 27.0)

These results come from probes and are locked in by tests in `ImageEngineTests`. Re-check them when the minimum macOS changes.

| Behaviour | Consequence | Handling |
|---|---|---|
| `kCGImageMetadataShouldExcludeGPS` only strips GPS from **JPEG**. PNG/TIFF/HEIC report success but keep the location | A naive implementation leaks location data | GPS tags are removed explicitly from the metadata. Every output is re-inspected and **rejected if GPS survives** a policy that removes it |
| `CopyImageSource` can't modify **AVIF** or **GIF** metadata, and PNG keeps GPS stored in its `eXIf` chunk | Metadata edits without re-encoding work only for JPEG, TIFF and HEIC | PNG/GIF are re-encoded losslessly (pixel-identical, tested). AVIF is re-encoded and the plan says so (`metadataEditRequiresReencode`), so keeping location avoids it |
| `kCGImageDestinationMetadata` cannot be combined with `kCGImageDestinationOrientation` | Removing all metadata loses orientation | Orientation is written as a TIFF tag inside the new metadata |
| The **AVIF encoder drops the orientation tag** | Rotated photos (e.g. from iPhones) come out sideways | Converting a rotated image to AVIF applies the rotation to the pixels (`appliesOrientation`, exact transform) |
| Output bit depth: HEIC/AVIF 10-bit, JPEG 8-bit, PNG 16-bit, TIFF up to 32 | Depth loss must be disclosed | Stored in `ImageFormat.maxBitsPerComponent`; a test compares it with the real encoder output |
| Transparency encoded to JPEG is composited onto white | Matches what users expect | Disclosed as `transparencyFlattened`; tested |
| **HEIF/AVIF encoding blocks on internal work and deadlocks** when every Swift cooperative-pool thread is inside an encoder | The app and tests hang under parallel load | All blocking media work runs on `MediaWork`'s dispatch queue, never directly on the cooperative pool. Cancellation is bridged with `CancellationToken`. **Test fixtures too:** a 3-core CI runner hung for 18 minutes when fixtures encoded HEIC/AVIF inline, so `FixtureFactory` is async on `MediaWork` |
| ImageIO writes AVIF on macOS 26.6 and 27.0, but not WebP or `public.heif` | libavif isn't needed; libwebp is | The runtime `writableFormats()` check stays in place |

## HDR gain maps (added 2026-09-29)

Measured with a real iPhone HEIC (Apple gain map, 4.0× headroom) by decoding every output with `kCGImageSourceDecodeToHDR`.

| Behaviour | Handling |
|---|---|
| Re-encoding drops the gain map unless it is copied explicitly | `CGImageSourceCopyAuxiliaryDataInfoAtIndex` → `CGImageDestinationAddAuxiliaryDataInfo` for JPEG, HEIC and AVIF (all keep 4.0×). PNG, TIFF and GIF can't store one, so `hdrDropped` is disclosed |
| Letting ImageIO re-derive an ISO gain map (`EncodeToISOGainmap`) keeps the headroom but changes the SDR image (33 dB vs 52 dB) | Not used. The camera's own gain map is copied |
| Apple gain maps depend on MakerApple tags 33/48. Without them HDR renders at 3.48× | "Remove all metadata" keeps those two tags (re-encode) or the maker note (metadata rewrite). They describe the image, not the person |
| Building **fresh** metadata for `CopyImageSource` drops the maker note. **Empty** metadata makes HEIC keep *everything*, including GPS | Remove-all trims a *copy* of the source metadata down to `tiff:Orientation` |
| AVIF output must rotate pixels (ADR above), so its gain map must rotate too | `RawBitmap.oriented`, a lossless pixel shuffle. A test checks it matches ImageIO's own transform for all 8 orientations |

Every plan that promises HDR is verified after writing: an output missing its gain map is never saved. For the reference photo, the difference in HDR rendering is 0.0 (HEIC), 0.004 (JPEG q95) and 0.003 (AVIF q95, rotated), against 0.10 with HDR dropped. Run the real-photo checks with `make test-hdr HDR_SAMPLE=~/path/IMG_1234.HEIC`. They are skipped in CI so no personal photos are committed.

## WebP output via libwebp (added 2026-09-29)

- ImageIO decodes WebP but cannot encode it, so libwebp 1.6.0 is vendored as the `CWebP` C target, with no build flags beyond a header search path.
- **Maximum quality is lossless WebP with `exact`.** Pixels, including the RGB under fully transparent areas, are bit-identical (tested). Lower quality selects lossy (`PRESET_PHOTO`, `method 5`, `sharp_yuv`).
- **Lossless effort 3:** on a 12 MP iPhone photo it takes 3.7 s and gives 5.62 MB, against 5.3 s and 5.61 MB at effort 6 (release build, M4 Pro). Lossy q85 takes 1.4 s and gives 561 KB.
- **WebP has no orientation tag that browsers honour**, so rotation is applied to the pixels, and stale `tiff:Orientation`/pixel-dimension tags are removed from the XMP.
- **Metadata** is written as an XMP chunk filtered by the policy. A test checks that keep-all carries GPS, so the path really works, and that the removal policies strip it. Colour profiles other than sRGB go into an ICCP chunk.
- **WebP is RGB-only.** Grayscale and CMYK are converted to sRGB, and the plan discloses it (`colourModelConverted`).

## Geometry: rotate/flip, crop, resize (added 2026-09-29)

| Decision | Why |
|---|---|
| **Rotate/flip** of JPEG, HEIC and TIFF only rewrites the orientation, so nothing is re-encoded | Lossless. Every mainstream viewer and browser honours EXIF orientation |
| **HEIC stores rotation in `irot`/`imir`.** Only `kCGImageDestinationOrientation` updates them, and that option can't be combined with `kCGImageDestinationMetadata` | Two lossless `CopyImageSource` passes: orientation into memory first, then metadata |
| **Lossless JPEG crop** with libjpeg-turbo `transupp` in stored-pixel space, followed by an orientation tag | No decoding. The top-left corner snaps to the iMCU grid (8 or 16 px, read from the file) and the plan reports it (`cropSnapped`). Decoded pixels match the original region away from the new edges (tested), including for rotated photos |
| The transform copies only ICC APP2 markers, never MPF | MPF would point to a gain map the crop doesn't carry. The lossless-crop plan discloses `hdrNotKeptByLosslessCrop`; "Exact pixels" re-encodes and keeps HDR |
| **Other formats:** orientation is an exact byte shuffle (`RawBitmap.oriented`) and crop uses `CGImage.cropping` | Straight alpha and 16-bit stay exact, so PNG/TIFF/lossless WebP output is bit-identical to the region (tested) |
| **Resize** uses vImage Lanczos (`kvImageHighQualityResampling`) in the image's own depth and colour space | Always disclosed as `resampled`. It is never offered as lossless, and the UI refuses to enlarge unless asked |
| **HDR gain maps** get the same orientation, a crop scaled to their resolution, and a proportional resize | HDR survives HEIC/JPEG/AVIF re-encodes with geometry (tested) |

## Compression (added 2026-09-29)

| Behaviour | Handling |
|---|---|
| **Lossless JPEG compression** is a libjpeg-turbo repack: Huffman optimisation, with progressive output 4–5% smaller than baseline on 12 MP photos | `optimize` gives a `.losslessJPEGTransform` without a crop. Pixels are identical (tested) |
| **Repacking can grow an already-tight small JPEG** | Compression never makes a file bigger: if the optimised output is not smaller, the plain lossless result is written instead |
| **ImageIO ignores TIFF `Compression` with `AddImageFromSource`, and ignores it when layout tags (tiles, photometric) are copied from the source** | TIFF output always goes through a decoded image with LZW and only the descriptive tags. A 12 MP photo shrinks from 36.9 MB to 10.9 MB losslessly |
| **HEIC, AVIF and GIF have no lossless repack** | `optimize` leaves them alone (copy or metadata only). "Smaller file" uses the quality slider |
| **A lower quality on a lossy format re-encodes even into the same format** | Previously JPEG → JPEG at quality 70 was a plain copy (bug) |
| **Size estimates** come from running the real conversion into a temporary folder (debounced, cancelled when settings change) | Every panel shows the true output size before export, e.g. "≈ 2.3 MB · 4% smaller" |
| **Removing metadata through ImageIO adds a ~2–3 KB XMP packet**, and a jpegtran repack can be less efficient than an already-optimised source. Together they made a 36 KB JPEG grow to 39 KB | JPEG "remove all" is a marker-level strip: tables and scans are copied byte for byte; only EXIF/XMP, vendor APPs, comments, MPF and trailing data are dropped. ICC, JFIF and Adobe are kept, plus a 32-byte orientation tag if needed. A repack is used only if it is smaller. Real file: 36,279 → 36,161 bytes |

## PDF (added 2026-09-29)

| Decision | Why |
|---|---|
| **JPEG pages are embedded as their original compressed data:** `CGImage(jpegDataProviderSource:)` → DCTDecode, after a marker-level metadata strip | No re-encode (the scan data is byte-identical inside the PDF, tested). The strip keeps EXIF/GPS out of the PDF |
| **Orientation is applied as a page transform**, not to the pixels | Rotated iPhone JPEGs stay untouched and come out upright |
| **Every page is stored as JPEG, set by one Quality slider.** At "Best", JPEG files go in untouched and other formats become JPEG 95; lower values re-encode every page | PDFs can't hold HEIC/WebP, and lossless (Flate) pages were far too big: a 12 MP HEIC made a 17.9 MB PDF, versus 2.5 MB at Best. The user asked for one simple size/quality control |
| **The preview is the real PDF**: the one built for the size estimate is rendered page by page | What you see is exactly what gets saved (page size, margins, edits) |
| **Pages are rendered with `CGPDFPage` on white** at 72–600 DPI | Rotation- and crop-box-aware. Output files are named `<name>-page-01.<ext>` and never overwrite existing ones |
| **Password-protected PDFs** prompt for the password; the unlock is kept only in memory | |

## Performance pass (added 2026-09-29; release builds, M4 Pro, 24 GB)

| Operation (100 MP JPEG) | Before | After | Change |
|---|---|---|---|
| → WebP lossy q85 | 17.7 s, 2.2 GB peak | **2.8 s**, 1.9 GB | Above 24 MP: no sharp YUV. Above 48 MP: effort 2 (+8% size). Above 24 MP lossy imports straight to YUV; the RGBA copy is freed right after import and the decoded image as soon as libwebp has its copy |
| Resize 50% | 1.1 s, 1.76 GB | **0.57 s, 640 MB** | Shrinking without a crop decodes at about the target size (ImageIO thumbnail, no transform), then fits exactly with vImage. A test shows a mean difference under 4/255 against full-resolution Lanczos |
| Long edge 2048 | — | **0.24 s, 119 MB** | Same path |
| → HEIC / JPEG, lossless JPEG crop / repack / strip | 0.2–1.3 s, 75–390 MB | unchanged | Already fine |
| → AVIF | 2.2 s, 1.8 GB | unchanged | The memory is inside ImageIO's AVIF encoder |

**App footprint** (as Activity Monitor reports it): about 100 MB with a 48–100 MP photo open. Crop's pixel loupe decodes full resolution (capped at 50 MP; above that an 8K decode) and is released when leaving Crop. The allocator keeps that memory for reuse, which shows as about 500 MB until the system reclaims it; reopening Crop doesn't grow it (checked with `malloc_history`: no live block).

## PDF editing (added 2026-09-29)

- **Editing is built on PDFKit** (`PDFEditor`), so text and vector content stay as they are and nothing is rasterised.
- **Rotation** changes only the page's /Rotate entry.
- **Text** is added as a FreeText annotation, so it stays selectable and editable in other apps.
- **Compression:** PDFKit's `saveImagesAsJPEGOption` and `optimizeImagesForScreenOption` had no effect on macOS 27. A Quartz filter built from the same settings as Preview's "Reduce File Size" works. Balanced is JPEG 0.8 at ≤200 DPI / 3000 px; Smallest is JPEG 0.6 at ≤144 DPI / 2000 px. A 3-page 2.9 MB test PDF went to 426 KB and 247 KB respectively, with text kept.
