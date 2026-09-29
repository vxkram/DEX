<p align="center"><img src="design/AppIcon-1024.png" width="128" alt="DEX icon"></p>

# DEX

**Take any image and quickly turn it into what you need.** DEX is a small (about 2 MB), native Mac app for converting, cropping, compressing, combining images and working with PDFs. It keeps quality whenever that's possible and tells you plainly when it isn't.

## What it does

| Tool | What you can do |
|---|---|
| **Convert** | JPEG, PNG, HEIC, WebP, AVIF, TIFF, GIF, in any direction. HDR photos stay HDR where the format allows. Location data is removed by default |
| **Crop** | Crop, rotate and flip, with aspect presets and a pixel-level zoom while you drag. JPEG crops are lossless |
| **Compress** | Lossless or smaller-file compression, smaller dimensions (4K / web / social), and the real resulting size shown before you save |
| **Compose** | Put images on top of each other (logos, watermarks) or join them side by side, stacked or in a grid, in any mix of formats |
| **PDF** | Make PDFs from images; turn PDF pages into images; rearrange, rotate, delete, extract, merge, split, add text or images to, and compress PDFs |

You can also right-click images in Finder: **Services → DEX ▸ Convert to JPEG / PNG / HEIC / WebP, Combine into PDF**.

## Requirements
- A Mac with Apple Silicon (M1 or newer)
- macOS 26 or later

## Install

### Option A: download the app (no Xcode needed)
1. Download **DEX.zip** (ask the owner for it, or get it from this repository's Releases page if there is one).
2. Double-click the zip, then drag **DEX.app** into your **Applications** folder.
3. Open it. The first time, macOS will say it can't verify the app, because it isn't notarised by Apple yet. To allow it:
   - open **System Settings → Privacy & Security**,
   - scroll down to the message about DEX, click **Open Anyway**, and confirm.

   You only need to do this once.

### Option B: build it yourself (needs Xcode)
1. Install **Xcode** from the Mac App Store (free, about 10 GB), open it once, then run:
   ```sh
   sudo xcode-select -s /Applications/Xcode.app
   ```
2. Install Homebrew from [brew.sh](https://brew.sh) if you don't have it, then:
   ```sh
   brew install xcodegen
   ```
3. Get the code and build:
   ```sh
   git clone https://github.com/vxkram/DEX.git
   cd DEX
   make package
   ```
4. The app is in **build/DEX.zip**. Unzip it and move DEX.app to Applications.

## Using it
1. **Drop an image or a PDF** onto the window (or click **Choose File…**).
2. Pick a tool from the dock at the bottom: **Convert, Crop, Compress, Compose, PDF, Info** (shortcuts ⌘1–⌘6).
3. Check the **Result** in the panel. It shows the format, the size of the file you'll get, and whether anything is lost. If a file will be bigger than the original, tap **Why?** to see the reason.
4. Click **Export** (⌘E) and choose where to save. **Your original file is never changed or overwritten.**

## Privacy
Everything happens on your Mac. DEX never uploads anything and has no network access. Location data is removed from exported photos unless you choose **Metadata → Keep**.

## Credits
Built with libjpeg-turbo, libwebp and Apple's frameworks. Details and licences are in **DEX ▸ About DEX**. For developers, see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
