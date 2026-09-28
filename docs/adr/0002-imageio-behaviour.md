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
| **HEIF/AVIF encoding blocks on internal work and deadlocks** when every Swift cooperative-pool thread is inside an encoder | The app and tests hang under parallel load | All blocking media work runs on `MediaWork`'s dispatch queue, never directly on the cooperative pool. Cancellation is bridged with `CancellationToken` |
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
