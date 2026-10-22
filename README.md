<p align="center"><img src="design/AppIcon-1024.png" width="128" alt="DEX icon"></p>

# DEX

**Take any image or sound and quickly turn it into what you need.** DEX is a small, native Mac app for converting, cropping, compressing and combining images, working with PDFs, and trimming and converting audio. It keeps quality whenever that's possible and tells you plainly when it isn't.

<p align="center"><img src="design/screenshot.jpg" width="800" alt="DEX with an image open and the Convert panel showing a lossless result"></p>

## What it does

| Tool | What you can do |
|---|---|
| **Convert** | JPEG, PNG, HEIC, WebP, AVIF, TIFF, GIF or PDF, in any direction. HDR photos stay HDR where the format allows. Location data is removed by default. **Advanced** has the quality slider, lossless repacking and smaller dimensions (4K / web), with the real resulting size shown before you save |
| **Crop** | Crop, rotate and flip to Free, 1:1, 3:4, 4:3, 16:9 or 9:16, with a pixel-level zoom while you drag. JPEG crops are lossless. **Fit** keeps the whole picture and fills the space around it with white, black, a colour, transparency or a blur, without touching the photo's own pixels |
| **Animations** | Animated GIFs and WebPs get a timeline: play them (Space), trim them and save as a GIF with each frame's own timing, or pick one frame and save it as a still |
| **Enhance** | AI upscaling 2× or 4× on your Mac: **Fast** or **Best** for photos (with noise and JPEG-block removal), **Anime** for drawings, and optional face restoration. Models download the first time (2–76 MB each). The result is always marked as AI-made |
| **Compose** | Put images on top of each other (logos, watermarks), join them side by side, stacked or in a grid, or place them freely on a **Canvas** of any size (Story, A4, Letter…), in any mix of formats |
| **PDF** | Make PDFs from images; turn PDF pages into images; rearrange, rotate, delete, extract, merge, split, add text or images to, and compress PDFs |
| **Audio** | Trim on a zoomable waveform, play it back, and save as WAV, AIFF, FLAC, ALAC, AAC or MP3. Trimming an MP3, AAC or ALAC doesn't re-encode it, and is still exact to the sample. Show and change the cover art, title and artist. Paste a YouTube link and choose on the next page: audio (AAC exactly as streamed, MP3, FLAC, ALAC, WAV, AIFF) or **video** in any quality up to 4K/8K, saved as MP4 without re-encoding |

You can also right-click images in Finder: **Services → DEX ▸ Convert to JPEG / PNG / HEIC / WebP, Combine into PDF**.

## Requirements
- A Mac with Apple Silicon (M1 or newer)
- macOS 26 or later

## Install

### Option A: download the app (no Xcode needed)
1. Download **DEX.zip** from the [Releases page](https://github.com/vxkram/DEX/releases).
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
1. **Drop an image, a PDF or an audio file** onto the window (or click **Choose File…**).
2. Pick a tool from the dock at the bottom: **Convert, Crop, Enhance, Compose, PDF, Info** for images (shortcuts ⌘1–⌘6), or **Trim, Convert, Info** for audio. The house button (⇧⌘H) takes you back to the start.
   For audio: Space plays, I and O set the trim at the playhead, and ⌘+ / ⌘− zoom (or pinch, or ⌥-scroll).
   To get audio or video from YouTube, paste the link on the start screen or choose **File ▸ Download from Link…** (⇧⌘O), press **Continue**, choose **Audio** or **Video**, pick a format or quality and **Download**. It's saved to Downloads.
3. Check the **Result** in the panel. It shows the format, the size of the file you'll get, and whether anything is lost. If a file will be bigger than the original, tap **Why?** to see the reason.
4. Click **Export** (⌘E) and choose where to save. **Your original file is never changed or overwritten.**

## DEX Mini for Chrome and Firefox
A small browser extension with the same look and the same honesty about quality. It lives in [`extension/`](extension/).
- **Edit images:** choose an image from the toolbar popup, or right-click any image on a page and choose **Edit with DEX…**. You can crop, rotate, flip, convert to PNG, JPEG or WebP, and resize, and the verdict tells you what each choice costs. Animated GIFs get a timeline: trim them, crop every frame, and save them as a GIF, or save one frame as PNG.
- **Screenshot any page:** drag a box over part of a page (Alt+Shift+S), or capture the whole visible page, and the shot opens in the editor. With a video on the page (YouTube included), **Save Video Frame** in the popup saves the current frame as a PNG at the video's full resolution.
- **Convert downloads automatically** (turn it on in the popup): WebP images arrive as PNG (or JPEG), and WebM video becomes MP4. The MP4 copies the streams untouched by default, or re-encodes to H.264 if you choose that, so it plays everywhere. Animated WebPs are left alone. If DEX can't convert a file, you keep the original.

It isn't in the browser stores yet. To try it, build it as described in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#browser-extension) and load it unpacked.

## Ideas & feedback
Have an idea, found a bug, or want a format DEX doesn't handle yet? Post it in **[Discussions](https://github.com/vxkram/DEX/discussions)**: ideas go under *Ideas*, questions under *Q&A*. Upvote the ideas you want most; that decides what comes next.

## Privacy
Everything happens on your Mac, and DEX never uploads anything. The app itself has no network access. There are two exceptions. One is **Download from Link**: a small helper inside the app fetches the downloader (yt-dlp, from its official GitHub release, checksum-verified) the first time you use it, and then fetches the audio or video you asked for. The other is **Enhance**: the same helper downloads the AI model you need from DEX's own GitHub release the first time, and DEX checks its fingerprint before using it. Your images are enhanced on your Mac and never uploaded. Nothing else goes online. Location data is removed from exported photos unless you choose **Metadata → Keep**. The browser extension also works entirely in your browser. It fetches only the images and downloads you act on, and it sends nothing anywhere.

## Credits
Built with libjpeg-turbo, libwebp, LAME (MP3, LGPL, shipped as its own replaceable library) and Apple's frameworks. Details and licences are in **DEX ▸ About DEX**. For developers, see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Licence
DEX is released under the [MIT Licence](LICENSE). The bundled third-party libraries keep their own licences ([docs/NOTICES.md](docs/NOTICES.md)).
