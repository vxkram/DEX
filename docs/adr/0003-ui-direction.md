# ADR 0003: Floating-glass UI direction

Date: 2026-09-29 · Status: accepted

## Decision
- **Layout:** the preview fills the window over a textured backdrop. A glass **action dock** runs along the bottom (Convert, Crop, Compress, Compose, PDF | Info; a PDF document gets only PDF and Info). Resizing lives in Compress as proportional "Dimensions" presets, so an image can never be stretched, and each action opens a glass **panel** on the right. The title bar is hidden, and the file name and facts sit beside the traffic lights.
- **Backdrop:** the grain texture (`App/Resources/Texture.heic`, 3840 px, ~1.3 MB, credited in `docs/CREDITS.md`) at 28% opacity over near-black, with darker edges that are heavier at the bottom. The texture is a fixed-size sheet that a layer view (`WallpaperView`) keeps still on screen while the window resizes, so a resize reveals more of it instead of zooming and sliding it. The window background is the same near-black, so edges never flash.
- **Depth (2026-10-05):** the backdrop is the back layer and glass floats above it. `floatingGlass` adds a cast shadow (its own area cut out, so the glass still sees the backdrop) and a top highlight edge. An ember light under the glass follows the pointer slowly, and the texture drifts a few points the opposite way (parallax). Dock buttons lift on hover and the selected one glows. The empty-state and link cards drift toward the pointer. There is no 3D tilt, because `rotation3DEffect` flattens Liquid Glass into an opaque card. All motion stops under Reduce Motion.
- **Accent:** molten ember `#F55C26`. It is the only brand colour; the verdict colours (green/teal/orange) keep their meaning.
- **Type:** SF Pro for UI and SF Mono for technical values (formats, dimensions, sizes). No bundled fonts.
- **Export:** a single step. Losses are listed in the panel, the button reads "Export with Loss…", and the Save panel's message repeats the losses. Stacking a confirmation dialog in front of the Save sheet made the sheet vanish on macOS 27, so there is no confirmation dialog.
- **Dock items for tools not built yet** are shown dimmed ("coming in a later build") so the layout is stable. Each lights up when its engine work lands.

## Why
- The user preferred the blur and texture. This layout grows by adding dock items rather than new sidebars.
- Everything stays native SwiftUI (Liquid Glass `glassEffect`, system controls), with no custom rendering.
