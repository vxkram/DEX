# ADR 0005: Audio trim, cut, split and convert

Date: 2026-09-29 · Status: accepted

## Decision
- **In the app: Trim, Convert, Info.** Cut and Split were built, then taken out of the UI for simplicity. The engine and its tests still do both (`AudioEdit.removed`, `AudioEdit.splits`).
- **Formats written:** WAV, AIFF, FLAC, ALAC (M4A), AAC (M4A), MP3. Anything AVFoundation can decode can be opened.
- **Engine:** a new `AudioEngine` target on AVFoundation/AudioToolbox, with the same planner model as images (`AudioPlanner` in `MediaModel`: No re-encode / Lossless / Lossy verdicts, notes, a lossless alternative).
- **Lossless routes, chosen before any encode:**
  - **MP3 trim → MP3: frame copy.** `MP3Stream` copies the original frames and writes a new Xing/LAME header. Two priming frames go in front, and the header's encoder delay tells the decoder to skip them, so the cut is **sample-exact and bit-identical** to decoding the source. When the bit reservoir reaches further back than the delay field (12 bits) allows, which happens with low VBR, the frame in front is replaced by a synthetic silent frame that carries the reservoir bytes.
  - **AAC/ALAC trim → same: AVFoundation passthrough** (`AVAssetExportPresetPassthrough` with a time range). ALAC is bit-exact. AAC packets are copied untouched; Apple's decoder rounds by a float ULP or two (about −130 dB) when it starts at the trim.
  - **Lossless source → WAV/AIFF/FLAC/ALAC: decode and store**, keeping bit depth and sample rate. This is bit-exact, including 32-bit integer audio into ALAC and WAV.
  - **MP3/AAC → WAV:** stored as 32-bit float, identical to the decode, peaks above full scale included. Into FLAC/ALAC/AIFF it becomes 24-bit, and the planner flags clipping when the analysed peak is above 1.0.
- **Only re-encoded when unavoidable:** cutting a section out of the middle of an MP3/AAC (the join can't be spliced losslessly: AVFoundation refuses multi-segment passthrough, and MP3 has no edit lists), a lossy target from another codec, or an explicit bit rate. The UI says so before export and offers FLAC. Split parts are planned one by one, so a part without a cut is still copied.
- **"Higher quality"** is not something a converter can add. Upsampling or going from 16 to 24-bit doesn't restore anything, so DEX keeps the source's rate and depth. Lossy → lossless is labelled "no additional loss", not "better".
- **MP3 encoding: LAME 4.0**, CBR at the chosen rate (320 kbit/s by default), quality 2, with a gapless Info header. AAC uses Apple's encoder at the highest quality.

## Why LAME, and why a separate library
- macOS 27 decodes MP3 but can't encode it (`afconvert -f MPG3` fails with `fmt?`). Ogg and Opus-in-Ogg can't be written either, so they're out for now.
- LAME is LGPL-2.0-or-later, and the repository is private with no licence. Linking LAME statically would oblige us to ship DEX's object files for relinking. Instead it lives in its own package (`Packages/Lame`, dynamic product `Lame`) and ships unmodified as `Contents/Frameworks/Lame.framework`, which users may replace. Its licence is in the About window.
- Verified: the hardened-runtime, ad-hoc-signed app loads the framework (tested in a debug build).

## Facts measured on macOS 27 (M4 Pro)
- Apple's decoder uses `frames × 1152 − delay − padding` from the LAME header, and only when the header's CRC is valid; the encoder name is not checked. A file without the header decodes with zero delay.
- `AVAudioFile` writes 16-bit FLAC as 24-bit (the bit-depth hint is ignored for FLAC but honoured for ALAC), so all non-MP3 output goes through `ExtAudioFile` with explicit format flags.
- Apple's FLAC encoder stops at 24-bit. AAC tops out at 48 kHz: higher rates are resampled, 88.2/176.4 kHz to 44.1 kHz.
- Every export is reopened after writing and checked for length, rate and channels before it's moved into place.

## Tags and artwork
- Title, artist, album and cover art are shown above the waveform, can be edited, and are written into MP3 (ID3v2: other frames of an existing tag are kept), FLAC (Vorbis comment and PICTURE blocks) and M4A (iTunes metadata by passthrough). This lives in the `AudioTagging` target. The audio data is never touched: tests check that an MP3 trim with new artwork still decodes bit-identically.
- On copy routes the tags are rewritten only if they changed, so an untouched MP3 trim is byte-for-byte the plain cut. WAV and AIFF are saved without tags, and the UI says so.

## Not yet
- Fades, gain, normalisation, Ogg/Opus output, and cutting MP3 losslessly across a join.
