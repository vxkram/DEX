# ADR 0007: DEX Mini, a browser extension

Date: 2026-10-22 · Status: accepted

## Decision
- A small Chrome and Firefox extension in `extension/`, separate from the Mac app. It shares only the design (`design/`, the texture) and the rules: the planner's verdicts and wording are ported, not the code.
- **What it does:**
  - The toolbar popup is a drop zone; dropping, pasting or choosing an image opens it in an editor tab with **Crop** (rotate, flip, aspect presets, pixel fields, drag handles), **Convert** (PNG, JPEG, WebP, quality) and **Resize** (75/50/25 %, 4K/Web/Social long edge, never enlarges).
  - Right-click any image: **Edit with DEX…**. Right-click a video or audio element: **Save as MP4 with DEX…**.
  - **Auto-convert** downloads: WebP becomes PNG (or JPEG), WebM becomes MP4. It's off until the user turns it on, which is when DEX asks for access to all sites.
- **Stack:** WXT (one MV3 codebase, Chrome and Firefox manifests), Preact (React's API in about 4 KB), plain CSS, Mediabunny for WebM. Zipped, the Chrome build is about 240 KB.

## Lossless-first in a browser
The extension can't do what ImageIO and libjpeg-turbo do on the Mac. Every pixel change goes through a canvas, which is 8-bit sRGB, premultiplied, and drops metadata. So the planner (`extension/src/lib/image/planner.ts`) says so instead of promising more:
- Nothing changed and the same format: the original bytes are saved (**No re-encode**).
- A JPEG crop or rotation is a re-encode (**lossy**), and PNG is offered as the lossless way out. There is no block-aligned lossless crop here.
- Loss notes the Mac app doesn't need: an embedded non-sRGB profile, more than 8 bits, semi-transparent pixels (premultiplication can shift them by a shade), metadata removed. Alpha is checked by scanning the pixels, so an opaque PNG with an alpha channel isn't marked down.
- **WebP at Max** is lossless only if this browser's encoder proves it at startup: an encode of noise at quality 1 has to decode back identically. Chrome passes; otherwise WebP is labelled lossy.
- File facts (lossless or lossy WebP, frame count, bit depth, ICC profile, alpha) come from reading headers (`image/sniff.ts`), not from guessing by extension.

## Animated GIF and WebP
- Frames are decoded with the browser's `ImageDecoder` (Chrome, and Firefox 133 and later), which also handles each frame's disposal. All frames are kept in memory, up to 1,000 frames and 150 megapixels in total.
- A timeline under the image shows a filmstrip, play/pause and a playhead. Its trim handles choose which frames a GIF keeps.
- Crop, Fit with a background, rotate, flip and resize apply to every frame.
- **GIF** is the default output for an animation. **PNG, JPEG or WebP** save the frame on the playhead as a still image. That's the user's choice, so it's noted, not counted as a loss.
- GIFs are written with gifenc. Each frame gets an **exact palette** when it has 256 colours or fewer, so cropping a GIF loses nothing. Only frames with more colours, for example after resizing or a blurred background, are quantized. Since only the encoder can know that, it reports it, and the verdict turns lossy. Partial transparency becomes fully clear or fully solid, and that's reported too.

## Screenshots
- **Select area** (popup, right-click, or Alt+Shift+S) injects a small overlay into the page: it dims the page, you drag a box, then the overlay removes itself, the page repaints, and `tabs.captureVisibleTab` captures it. The crop is converted from CSS pixels to the capture's own pixel size, not `devicePixelRatio`, which page zoom changes. **Visible page** skips the overlay.
- **Save video frame** (right-click a video) draws the `<video>` into a canvas inside the page, at the video's own resolution, not the screen's. A cross-origin or DRM-protected video can't be read that way, and DEX says so and suggests Select area instead.
- No new permissions: `activeTab` is granted by the click or the shortcut, and `scripting` injects the overlay. Browser pages and add-on stores can't be captured, and DEX says so.
- Shots open in the editor as PNG, named like macOS screenshots.

## Downloads
- The extension can't change a file while it downloads, or read one that's been saved. So DEX lets the download finish, **fetches the URL again**, converts that copy, and saves it next to the original with a new extension. Only once the converted file has been written does it delete the original, unless **Keep the originals too** is on.
- When anything fails, the original simply stays and a notification says why. Examples: the site refuses a second request, the file is a `blob:` the page made, it's over the size limit, or the codec can't be copied.
- An **animated WebP is left alone**, because PNG and JPEG would keep only its first frame.
- **WebM → MP4 (default)** is a remux: the VP9/AV1 and Opus streams are copied untouched. It's checked against what MP4 can hold first, so it can never quietly turn into a re-encode. MP4 with VP9 plays in browsers and VLC, but not QuickTime. **MP4 · H.264** re-encodes through WebCodecs (lossy, plays everywhere) and is offered only when the browser can encode H.264 and AAC.
- Chrome's service worker can't make blob URLs or run WebCodecs, so conversions run in an offscreen document. Firefox runs them in its background page.

## Not done
- AVIF and HEIC output: browsers don't encode them.
- Downloads go to the default folder. An extension can't save next to a file the user put elsewhere with "Save as…".
