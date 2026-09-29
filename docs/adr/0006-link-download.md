# ADR 0006: Download from Link (YouTube)

Date: 2026-09-29 · Status: accepted

## Decision
- Paste a YouTube or YouTube Music link, on the drop screen or via **File ▸ Download from Link…** (⇧⌘O), and press Continue. A **format page** looks the video up (thumbnail, title, channel, length, and the AAC stream's real bit rate) and lists **AAC (M4A), MP3 (320/256/192/128), FLAC, ALAC, WAV, AIFF**, each with a line on what it means. **Download** saves that format to `~/Downloads`; then you can open it in the editor or show it in Finder.
- **Where the formats come from:** YouTube only stores AAC (about 128 kbit/s) and Opus (about 160 kbit/s, in WebM, which macOS can't read). Every format is made from the AAC stream. The **AAC** row saves it exactly as streamed, with no re-encoding, and is marked **Best quality** and selected by default. **MP3** re-encodes it, which is what every "YouTube to MP3" site does, and the page says so. A higher MP3 bit rate doesn't restore detail. FLAC, ALAC, WAV and AIFF store the decoded audio with no further loss: bigger, not better.
- **How it's saved:** the helper downloads the AAC into a hidden `~/Downloads/.DEX downloading/` folder. The app then moves it, or converts it with the audio engine, including the tags and cover. The hidden folder is then removed, so only the chosen file is left.
- **Video:** the page's **Audio | Video** switch lists every quality YouTube has that macOS can play without converting, highest first and selected by default (e.g. 2160p60 4K, 1440p60, 1080p60…), with codec and size. They're saved as **MP4** (title and thumbnail included) with nothing re-encoded. The helper downloads the video-only stream plus the AAC audio (`-f <id>,140`) and joins them with an AVFoundation passthrough (`VideoMuxer`).
  - **Codecs:** above 1080p YouTube offers only AV1 and VP9. macOS can't play VP9 (tested: VP9 in MP4 over HLS reports not playable; WebM isn't readable at all), so VP9 is left out, and the page says when a video's top resolution exists only as VP9. AV1 plays on Macs with M3 or newer, iPhone 15 Pro and later, and modern browsers. **Plays everywhere** limits the list to H.264, which YouTube has up to 1080p. HLS (m3u8) streams are skipped: they're slow to fetch and duplicate the DASH ones.
  - **Length fix:** YouTube's split streams claim twice their real length in their headers (yt-dlp normally repairs this with ffmpeg). Joined naively, a 10:34 video showed as 21:09. `VideoMuxer` measures each stream's real end from its last sample, joins exactly that, and then checks the result has two tracks of the planned length.
  - **4K / 1440p in H.264 (converted):** YouTube encodes H.264 only up to 1080p, so under **Plays everywhere** the larger sizes are offered as **Converted**. DEX downloads the AV1 stream, decodes it, and encodes H.264 with the hardware encoder at about YouTube's own upload recommendation (4K60 45 Mbit/s, 4K30 35, 1440p60 24, 1440p30 16) so the second encode costs little. The audio is copied untouched (`VideoConverter`). These sizes are never the default. The page explains the trade-off (a small loss, a larger file, a few minutes), and sizes are shown as an upper bound. Measured on an M4 Pro: 10:34 of 1440p60 took about 5 minutes, download included, and came to 1.25 GB against a 1.9 GB ceiling. HDR is left out, since this H.264 path is 8-bit.
- **Tags:** the video's title, artist (or channel), album (YouTube Music) and thumbnail (as a JPEG) are written into the M4A by a metadata passthrough, without touching the audio.
- **Downloader:** yt-dlp (public domain, Unlicense), which is fetched on first use (~37 MB) from the official GitHub release (`releases/latest/download/yt-dlp_macos`). It's installed only if its SHA-256 matches the release's `SHA2-256SUMS`. It lives in `~/Library/Application Support/DEX/Tools/`. When a download fails, DEX runs `yt-dlp -U`, which checks its own release signature, and tries once more. This keeps working after YouTube changes without a DEX release.
- **It runs in an XPC service** (`DEXDownloader.xpc`, bundled in the app). The service is **not sandboxed**; the app still is, and the app has no network access.

## Why an XPC service
Tried first, inside the sandboxed app: the download and checksum worked, but macOS quarantines every file a sandboxed app writes, and it refuses to launch quarantined programs (`Process.run` reports "file doesn't exist"). Removing the flag with `removexattr` returns `EPERM` under the sandbox. So a sandboxed app cannot run a program it downloaded. The other options were:
- bundling yt-dlp: +37 MB, and it can't update itself inside the signed app;
- dropping the sandbox for the whole app.

A separate service keeps the main app sandboxed and offline, and isolates the part that talks to the network and runs a third-party program.

## Limits on the service
- It runs one fixed program, `Tools/yt-dlp_macos`, with a fixed argument array (never a shell). The link must pass `LinkDownloader.link(in:)`: http(s) and YouTube hosts only.
- It writes only to its staging folder and then to `~/Downloads`, never replacing an existing file.
- Cancelling or closing the app ends the download.

## Not in the App Store
A non-sandboxed service isn't allowed there, and neither is a YouTube downloader. This feature is for direct distribution only. Users are asked to download only audio they have the right to use.
