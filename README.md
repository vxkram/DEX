# DEX

A native macOS media utility: drop a file, choose an action, export. Lossless whenever physically possible, never silently lossy.

Status: **Phase 1**. The engine and CLI can inspect and convert JPEG, PNG, HEIC, AVIF, TIFF and GIF with a lossless-first planner. The app window (floating-glass UI) converts between all of them plus WebP, and crops, rotates and resizes, losslessly where the format allows. See [`docs/PLAN.md`](docs/PLAN.md).

## Requirements
- macOS 26+ on Apple Silicon
- Swift 6.2+ (Command Line Tools are enough for the package; **full Xcode** is required for the app target)

## Layout
```
Packages/DexCore/     SwiftPM package: engine + CLI + tests (no UI)
  Sources/MediaModel/     Value types and quality rules (Foundation only)
  Sources/JobSystem/      Safe output (temp + atomic move) and the media work queue
  Sources/ImageEngine/    ImageIO-backed image processing
  Sources/dex-cli/    `dex` command-line tool
docs/                     Plan, original brief, architecture decision records (see adr/0002 for measured ImageIO quirks)
```

## Common tasks
```sh
make test                                   # run all tests
make formats                                # which image formats this Mac can read/write
make run                                    # build and launch the app
scripts/make-app-icon.sh my-icon-1024.png   # replace the app icon (1024×1024 PNG)
make cli ARGS="inspect ~/Pictures/a.heic"   # inspect a file (add --json for machine output)
make cli ARGS="convert a.heic --to png"      # lossless: runs straight away
make cli ARGS="convert a.heic --to jpeg"     # lossy: explains what's lost and waits for --allow-lossy
make cli ARGS="convert a.heic --to jpeg --dry-run"  # show the plan only
```
