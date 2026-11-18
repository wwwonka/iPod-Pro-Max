# yt-dlp Plug-in

ID: `yt-dlp`
Roles: `resolver`, `downloader`

Last-resort audio search and download from YouTube / YouTube Music for iPod Pro Max using embedded `yt-dlp` and `deno`, plus the app's `ffmpeg`.

## Vendor binaries

Run `./Tools/Build/fetch-ytdlp-vendor.sh` to download pinned `yt-dlp` and `deno` binaries into `Plug-ins/yt-dlp/vendor/` with SHA256 verification.

## Verification

```sh
swift build --product YtDlpPlugin
mkdir -p Plug-ins/yt-dlp/bin/macos
cp .build/debug/YtDlpPlugin Plug-ins/yt-dlp/bin/macos/yt-dlp-plugin
swift run ipodpromax plugin test Plug-ins/yt-dlp --offline
```
