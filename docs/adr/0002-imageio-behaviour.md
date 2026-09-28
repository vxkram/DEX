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
