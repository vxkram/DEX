# ADR 0004: Finder right-click through macOS Services

Date: 2026-09-29 · Status: accepted (this resolves the plan's Finder Sync vs Services question)

## Decision
The right-click actions are **NSServices** declared in Info.plist and handled by `FinderServices` in the app:
- DEX ▸ Convert to JPEG / PNG / HEIC / WebP
- DEX ▸ Combine into PDF
- DEX ▸ Open in DEX

## Why
- **Nothing to install or enable.** An empty `NSRequiredContext` enables the services by default, whereas a Finder Sync extension has to be switched on in System Settings.
- **No second target.** There's no extension process and no app ↔ extension communication to maintain.
- **Submenu for free.** The "DEX/…" menu titles group the items into a submenu.
- **The same engine** as the app, with the same verification and SafeOutput.

## Sandbox
- Service pasteboards grant read access to the selected files but not write access to their folder.
- The first quick convert in a folder shows an `NSOpenPanel` ("Allow DEX to save converted images in …"). The grant is stored as a security-scoped bookmark per folder, so later conversions there don't ask. This was verified with `NSPerformService`: the second and third services ran with no prompt.
- Results never overwrite anything and are selected in Finder afterwards. Failures show one alert.

## Later
A Finder Action Extension, a popup with format and quality choices, is the planned richer version.
