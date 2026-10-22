# DEX Mini

The Chrome and Firefox extension. It crops, converts and resizes images in DEX's glass look, and turns WebP and WebM downloads into PNG and MP4. See the [ADR](../docs/adr/0007-browser-extension.md) for how it works and what it can't do in a browser, and [DEVELOPMENT.md](../docs/DEVELOPMENT.md#browser-extension) for the commands.

```
src/entrypoints/
  popup/                  toolbar popup: Choose Image, Open DEX, download settings
  editor/                 editor tab: Crop, Resize, Convert, and the GIF timeline
  background.ts           context menus, download auto-convert
  offscreen/              Chrome only: runs conversions (blob URLs, WebCodecs)
src/lib/
  image/                  planner (verdicts, worded as in the Mac app), sniff (file facts
                          from headers), crop maths, canvas codec, GIF frames and encoding
  media/                  WebM → MP4 with Mediabunny, H.264/AAC capability check
  downloads/              re-fetch and convert a finished download; auto-convert settings
  shared/                 file names; handing a file from the popup to the editor
src/components/           glass UI pieces: backdrop, controls, icons
src/styles/glass.css      the Mac app's tokens and glass, in CSS
tests/                    vitest
store/                    addons.mozilla.org listing text and screenshots
```

## Building from source (for add-on reviewers)
Built on macOS 26 with Node 26 and npm 11 (Node 22+ works). Every dependency is pinned in `package-lock.json`.

```sh
npm ci                       # installs the exact versions; postinstall runs `wxt prepare`
npx wxt zip -b firefox       # builds and packs the Firefox add-on
```
The add-on is then in `.output/firefox-mv3/`, and its zip is `.output/dex-extension-0.1.3-firefox.zip`.

The build is WXT (on Vite/Rollup): it bundles and minifies the TypeScript and Preact in `src/` and copies `public/` as-is. Third-party code comes only from npm: `preact` (UI) and `mediabunny` (WebM → MP4). Nothing is fetched at runtime.
