# DEX

A native macOS media utility: drop a file, choose an action, export. Lossless whenever physically possible, never silently lossy.

Status: **Phase 0 / early Phase 1**. The core engine and CLI exist; the app UI does not yet. See [`docs/PLAN.md`](docs/PLAN.md).

## Requirements
- macOS 26+ on Apple Silicon
- Swift 6.2+ (Command Line Tools are enough for the package; **full Xcode** is required for the app target)

## Layout
```
Packages/DexCore/     SwiftPM package: engine + CLI + tests (no UI)
  Sources/MediaModel/     Value types and quality rules (Foundation only)
  Sources/ImageEngine/    ImageIO-backed image processing
  Sources/dex-cli/    `dex` command-line tool
docs/                     Plan, original brief, architecture decision records
```

## Common tasks
```sh
make test                                   # run all tests
make formats                                # which image formats this Mac can read/write
make cli ARGS="inspect ~/Pictures/a.heic"   # inspect a file (add --json for machine output)
```
