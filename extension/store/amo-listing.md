# DEX Mini — addons.mozilla.org listing

Copy each field into the Developer Hub form.

## Name
DEX Mini

## Add-on URL (slug)
dex-mini

## Summary (max 250 characters)
Crop, convert and resize images in your browser, with an honest verdict on quality. Trim and crop GIFs on a timeline. Turns WebP downloads into PNG and WebM into MP4 automatically, losslessly whenever possible.

## Description
Paste everything between the lines. AMO supports **bold**, *italic*, [links](url), `-` lists and `>` quotes, but no headings, so the sections use bold lines. Don't include the `---` lines themselves.

---
DEX Mini brings the [DEX](https://github.com/vxkram/DEX) image tools to Firefox, with the same rule: **lossless whenever possible, and it tells you plainly when it isn't.**

**Edit any image**

- Right-click an image on a page and choose *Edit with DEX…*, or pick one from the toolbar button
- Crop to 1:1, 4:3, 3:4, 16:9, 9:16, or any custom ratio or exact pixel size
- Fit the whole image into a shape, with a blurred, coloured or transparent background around it
- Rotate, flip, and resize (75%, 50%, 25%, 4K, Web, Social)
- Convert to PNG, JPEG or WebP, and rename the file before saving

**Animated GIFs**

- A timeline with play/pause and trim handles
- Crop and resize every frame, then save as a GIF, or save the frame you're on as a PNG
- Frames keep their exact colours whenever they fit GIF's 256-colour limit

**Know what you lose**

Every export shows a verdict before you save: *No re-encode*, *Lossless* or *Re-encode (lossy)*, with the reasons listed, such as:

> JPEG encoding at quality 95

> Transparency will be flattened onto white

When a lossless option exists, DEX offers it.

**Convert downloads automatically** (optional, off until you turn it on)

- **WebP** images arrive as PNG (lossless) or JPEG
- **WebM** video becomes MP4. By default the streams are copied untouched, with no re-encoding. You can choose H.264 instead, which plays everywhere
- Animated WebPs are left as they are, and if anything can't be converted you keep the original

**Private by design**

Everything happens inside your browser. DEX Mini doesn't upload, track or collect anything. It reads only the images you open and the downloads you ask it to convert.

Open source under the MIT licence: [github.com/vxkram/DEX](https://github.com/vxkram/DEX)
---

## Categories
Photos, Music & Videos; Download Management

## Tags
image, crop, convert, webp, png, gif, resize, webm, mp4

## Support site
https://github.com/vxkram/DEX/discussions

## Homepage
https://github.com/vxkram/DEX

## License
MIT License

## Privacy policy
Not required: the add-on collects no data (manifest declares `data_collection_permissions: none`). If asked, use:
"DEX Mini processes images and downloads entirely on your device. It does not collect, store or transmit any personal data, and makes no network requests except re-fetching a file you downloaded or opened, from the site it came from."

## Notes to reviewer
Built with WXT (Vite). Source and build steps: README.md in the source zip (`npm ci && npx wxt zip -b firefox`). Third-party code: preact (UI), mediabunny (WebM → MP4 remux), gifenc (GIF encoding), all from npm.

Permissions:
- `downloads`: auto-converting WebP/WebM downloads (off by default) and saving edited images.
- `<all_urls>` (optional host permission): requested only when the user turns auto-convert on or opens a remote image in the editor, to fetch that file again and convert it locally.
- `contextMenus`: "Edit with DEX…" and "Save as MP4 with DEX…".
- `scripting` + `activeTab`: reading a `blob:` image from the tab the user right-clicked.
- `notifications`: saying when a download was converted or kept.
- `storage`: the user's auto-convert settings.

The innerHTML warning is in bundled Preact (its `dangerouslySetInnerHTML` support); the add-on never uses that prop.

## Screenshots (1280 × 800), in order
1. `1-convert.png`: Convert with the live quality verdict
2. `2-crop-fit.png`: 1:1 fit with a blurred background
3. `3-gif-timeline.png`: trimming an animated GIF on the timeline
4. `4-popup.png`: the toolbar popup and download settings

## Screenshot credits
The photo in screenshots 1–3 is "Pagoda surrounded by trees" by Su San Lee on Unsplash (https://unsplash.com/photos/pagoda-surrounded-by-trees-E_eWwM29wfU), free under the Unsplash License. The GIF in screenshot 3 is a pan across the same photo, made for these screenshots.
