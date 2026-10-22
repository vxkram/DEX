# Developing DEX

## Requirements
- macOS 26+ on Apple Silicon
- Xcode 26+ (`sudo xcode-select -s /Applications/Xcode.app`)
- XcodeGen: `brew install xcodegen` (generates `DEX.xcodeproj` from `project.yml`)

## Layout
```
App/                      SwiftUI app (UI only)
Packages/DexCore/     SwiftPM package: engine + CLI + tests (no UI)
  Sources/MediaModel/     Value types, planner and quality rules (Foundation only)
  Sources/JobSystem/      Safe output (temp file + atomic move) and the media work queue
  Sources/ImageEngine/    ImageIO / vImage / PDFKit processing, WebP and lossless JPEG
  Sources/CWebP/          Vendored libwebp (scripts/vendor-libwebp.sh)
  Sources/CJPEGTurbo/     Vendored libjpeg-turbo (scripts/vendor-libjpeg-turbo.sh)
  Sources/AudioEngine/    AVFoundation / AudioToolbox audio: waveform, MP3 frame copy, export
  Sources/Downloader/     yt-dlp install (checksum-verified), updates and runs, for YouTube links
  Sources/dex-cli/    `dex` command-line tool
Packages/Lame/            LAME MP3 encoder (LGPL) as its own dynamic library (scripts/vendor-lame.sh)
DownloaderService/        XPC service that runs yt-dlp for Download from Link (not sandboxed; ADR 0006)
extension/                DEX Mini, the Chrome/Firefox extension (WXT + Preact; ADR 0007)
docs/                     Plan, original brief, architecture decisions (adr/)
design/                   App icon master (1024 px)
```

## Common tasks
```sh
make test                                   # run all tests
make run                                    # build and launch the app (debug)
make package                                # build a shareable zip: build/DEX.zip
make xcode                                  # open the project in Xcode
make formats                                # which image formats this Mac can read/write
make test-hdr HDR_SAMPLE=~/Pictures/x.heic  # extra checks against a real iPhone HDR photo
scripts/make-app-icon.sh my-icon-1024.png   # replace the app icon
make cli ARGS="inspect ~/Pictures/a.heic"   # inspect a file (add --json)
make cli ARGS="convert a.heic --to png"     # convert (lossy results need --allow-lossy)
```

## Browser extension
Needs Node 22+. Run these in `extension/`:
```sh
npm install
npm run dev            # Chrome with the extension loaded, reloading on save
npm run dev:firefox    # the same in Firefox
npm test               # planner, crop maths, file sniffing
npm run check          # TypeScript
npm run zip            # .output/*-chrome.zip and *-firefox.zip for the stores
```
To try a build by hand: open `chrome://extensions`, turn on Developer mode, then **Load unpacked** and pick `extension/.output/chrome-mv3`. In Firefox, open `about:debugging` → This Firefox → **Load Temporary Add-on**, and pick `extension/.output/firefox-mv3/manifest.json`.

See `docs/PLAN.md` for the roadmap and `docs/adr/` for why things are built the way they are.
