# Ancienne application SwiftUI — référence de portage

Cette application macOS est conservée pour récupérer les fonctionnalités encore absentes de l’application principale SwiftCrossUI. Ouvrir `iPod Pro Max.xcodeproj` dans ce dossier. Le package partagé reste à la racine du dépôt.


## Prérequis de compilation

Depuis la racine, ouvrir `Refs/SwiftUI/iPod Pro Max.xcodeproj` ou compiler avec `xcodebuild -project "Refs/SwiftUI/iPod Pro Max.xcodeproj" -scheme "iPod Pro Max"`.

Le projet Xcode embarque `Build/FFmpeg/macos-universal/ffmpeg`. Ce fichier généré n’est pas dans Git : le produire avec `Tools/FFmpeg/build.sh` avant d’assembler l’ancienne app. Lors de la vérification du rangement, les sources Swift ont compilé mais cette copie de ffmpeg était absente, empêchant l’assemblage final du bundle. L’application SwiftCrossUI se compile indépendamment avec `Tools/Build/build.sh mac`.

---

# iPod Pro Max

A Mac app that syncs music, videos, podcasts, audiobooks and photos to classic click-wheel iPods (iPod Video, nano 1st/2nd gen, photo, mini, classic, and the original iPods). No iTunes, no Finder sync, no libgpod dependency: the iPod database format is implemented in Swift.

Roadmap for the portable, cross-platform (macOS / Windows / Linux) version: see [`Docs/`](../../Docs/README.md) (an Obsidian vault, in French).

## How it works

- **Device** (`iPod Pro Max/Device/`): detects mounted iPods (`iPod_Control` folder on a local removable volume), identifies the model from `SysInfo`, `SysInfoExtended`, or the USB product id when those are empty, and knows each generation's artwork sizes and database-signature requirements.
- **Core** (`iPod Pro Max/Core/`): reader and writer for `iTunesDB` (tracks, videos, playlists, podcast/audiobook groups, library sort indexes), `ArtworkDB` + `.ithmb` RGB565 thumbnails, the `Photo Database` (`Photos/`) with RGB565 / UYVY / I420 thumbnails and albums, the `Play Counts` file the iPod writes, and the hash58 signature used by iPod classic / nano 3G–4G.
- **Library** (`iPod Pro Max/Library/`): the app's own library (JSON in `~/Library/Application Support/iPod Pro Max`), metadata extraction with AVFoundation, a Music-app catalog (iTunesLibrary framework) with per-item sync status, Photos-app album access (PhotoKit), podcast subscriptions (RSS, OHdio, YouTube — see below) and downloads, audiobook folder scanning and multi-chapter merging, AAC transcoding for audio formats the iPod can't play, H.264 Baseline 1.3 / 320×240 video conversion (AVAssetWriter, with the declared level patched in the MP4 so the iPod accepts it), and an ID3v2.4→2.3 lyrics tag fixup.
- **Sync** (`iPod Pro Max/Sync/`): incremental sync engine (reads play counts back, copies new files into `F00…F49`, removes deselected ones, rebuilds playlists and artwork, writes the database atomically) plus the main-actor coordinator that drives the UI.
- **UI** (`iPod Pro Max/UI/`): SwiftUI views for devices, music (by-artist master-detail or a flat sortable table), videos, playlists, podcasts, audiobooks, photos, the Music import chooser, and settings.

### Apple Music
Songs from an Apple Music subscription are FairPlay-encrypted; no iPod can play them, so the Music import chooser lists them as "Apple Music (protected)". iTunes Store purchases, CD rips and files import normally. Items that live only in iCloud show as "Not downloaded" until they are downloaded in the Music app.

### Podcasts beyond RSS
Pasting a feed URL still works as before, but "Add Podcast" also recognizes two other kinds of link and converts them to the same `PodcastShow`/`PodcastEpisode` shape transparently (`Library/PodcastSourceKind` picks the source from the URL):

- **Radio-Canada OHdio** (`.../ohdio/balados/<id>/<slug>`): talks to the same private GraphQL API the OHdio web player uses (`Library/OHdioFeed.swift`), no external service required. Episode audio is resolved to a real CDN URL lazily, right before download.
- **YouTube** (a channel or playlist URL): lists videos as episodes and extracts audio on download via `yt-dlp` (`Library/YouTubeFeed.swift`) — YouTube has no public API for this, so this is a thin wrapper around a well-maintained external tool rather than a reimplementation of YouTube's private player API. The show's artwork is the channel's profile picture, not a video thumbnail. Settings › YouTube can point it at a signed-in browser's cookies (`--cookies-from-browser`) to fix "sign in to confirm you're not a bot" and age/member-restricted videos — YouTube has no sign-in API for third-party apps, so this is the realistic equivalent of "logging in."

### Audiobooks
A folder you point the app at (Audiobooks › Choose Folder) is scanned into books: a subfolder with multiple files becomes a multi-chapter book, a loose file becomes a one-part book (`LibraryStore.collectAudiobookFiles`). Chapter tags are deliberately homogenized (one author/artwork per book, taken from whichever chapter has it) so a book doesn't fragment into several "albums" on the device.

Multi-chapter books are **merged into a single cached `.m4b`** at sync time (`Library/AudiobookMuxer.swift`), with real QuickTime chapter markers, instead of syncing as N separate iPod tracks — a book played as separate tracks has no continuous playback and one bookmark per chapter instead of one per book. This goes through `ffmpeg` for the concat + chapter authoring (hand-authoring the chapter track's raw `tx3g` samples with AVFoundation is possible but much more fragile); if `ffmpeg` is missing or the merge fails, the sync falls back to syncing chapters separately rather than failing outright.

### External dependencies
Two optional command-line tools (expected via Homebrew, auto-detected in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`) unlock extra features; the rest of the app works without them:

- **`yt-dlp`** — YouTube-as-podcast (listing + audio extraction).
- **`ffmpeg`** — merging multi-chapter audiobooks into one `.m4b` with chapters.

### Lyrics
The classic's Lyrics screen only reads the ID3v2.3 `USLT` frame; it silently ignores lyrics tagged in ID3v2.4 (what most modern taggers write by default) and never supports the synchronized `SYLT` frame. `Library/LyricsTagFixup.swift` rewrites an MP3's ID3 tag to v2.3 at sync time, byte-preserving every frame (so `USLT` survives as `USLT`, not as a generic `TXXX` — re-tagging through `ffmpeg`'s own ID3 writer was tried first and silently did exactly that, which is why this is done by hand instead). Tracks already on an iPod are automatically re-copied once to apply the fix, tracked per-device by the source file's modification date so it isn't repeated every sync.

### Library file compatibility
`LibraryStore` persists as JSON; `Codable`'s synthesized decoder requires every non-optional field to be present, so adding a new non-optional field to `LibraryTrack`/`PodcastShow`/`DeviceSyncRecord` would make any library saved before that change fail to decode entirely. `LibraryStore.backfillMissingKeys` patches the raw JSON to fill in such fields before decoding, so older library files keep loading as the schema grows. `saveNow()` also refuses to write an all-empty document over a non-trivial existing file — normal use never empties tracks, playlists, shows and device records all at once, so that combination most likely means a load failed, not that the library is really meant to be cleared.

## Supported iPods (1.0)

| Model | Status |
| --- | --- |
| iPod Video (5th / 5.5 gen), nano 1G/2G, photo/color, mini, iPod 1G–4G | Full |
| iPod classic (160 GB, 2009) | Full (confirmed on hardware) |
| iPod classic (80/120/160 GB, 2007–2008), nano 3G/4G | Experimental (same signed-database mechanism, untested on hardware) |
| nano 5G+, shuffle, touch | Not supported |

Apple Music / DRM-protected songs are skipped because the iPod can't play them.

## Other notable behavior

- **Sync options per iPod**: "Use Album Artist for Grouping" replaces a track's Artist with its Album Artist on-device only (so a various-artists album doesn't fragment across the Artists list / repeat itself in Cover Flow); your library files are never modified. Albums also get a chronological sort key (`SortKey`/`SyncEngine.chronoSortAlbum`) — the on-device title stays the real album name, only its alphabetical position moves.
- **Videos** can be tagged Movie / TV Show / Music Video (`VideoCategory`), which drives the separate iPod Videos submenus directly via the track's `mediaType` bits — no special playlist needed, unlike Podcasts.
- **Missing files**: `LibraryStore.missingPaths` is a background-refreshed cache (never a disk check per table row — that alone made large libraries sluggish) backing a "Remove Missing Files" action in Music/Videos.
- **Edited tags**: before each sync, `refreshChangedTrackMetadata` re-reads any file whose modification date moved since the last scan (in parallel, a couple of seconds even for a big library) so edits made in another app reach the iPod without a re-copy or a duplicate.
- Sidebar library items (Music/Videos/Podcasts/Audiobooks/Photos) can be dragged into a custom order, persisted in `UserDefaults`.
- **Fast imports**: `importFiles` reads files in parallel (one task per core, `activeProcessorCount`), stores each distinct embedded cover once (`ArtworkKeyCache`), and appends to the library in ~500 ms batches so the UI isn't regrouped per file — 5,299 files in ~9 s vs ~78 s serially (`dbtest --import-bench`).
- **Library folder**: `LibraryDocument.musicFolderPath` is scanned at launch (`scanLibraryFolders`, toggle in Settings) and from Library ▸ Scan Library Folder for New Files (⌥⌘R): it imports new files, rescans the Audiobooks folder, re-reads edited tags and refreshes missing files — it never removes anything, since an unplugged drive looks like an empty folder. Libraries from before this setting adopt the common folder of their songs (`inferMusicFolderIfNeeded`) unless it's too broad (~, ~/Music, the Music app's media folder).
- **Artist photos** (Music view only — iPods don't show them): `ArtistPhotoStore` looks each artist up once on Deezer's public API (exact name match, collaborations fall back to their lead artist, requests paced under Deezer's 50-per-5 s limit) and saves 600-px JPEGs plus an `index.json` in `Application Support/iPod Pro Max/Artist Photos`. Misses are remembered for 30 days; network/quota failures aren't. Right-click an artist ▸ Choose Artist Photo… to override. `dbtest <artists.txt> <dir> --artist-photos` tests matching.
- **Thumbnails**: `ThumbnailCache` keeps decoded, display-sized artwork in memory (ImageIO downsampling, 64 MB NSCache), and `ArtworkThumb` reads it synchronously on init — revisiting an artist shows artwork on the first frame instead of re-decoding from disk.
- **Drag to iPod**: songs (multi-selected in either Music view — click-and-drag on unselected songs sweeps a range in By Artist), albums (by their artwork) and artists can be dragged onto an iPod in the sidebar. They're set to sync and `SyncCoordinator.scheduleSync` starts a sync once drops settle, waiting for a running sync to finish first.

## Permissions and entitlements
The app is not sandboxed but uses the Hardened Runtime, so access to protected resources needs both a usage string in Info.plist and a resource-access entitlement in `iPod Pro Max/iPod Pro Max.entitlements`, otherwise macOS denies silently without showing a prompt:

- Photos: `NSPhotoLibraryUsageDescription` + `com.apple.security.personal-information.photos-library`
- Music app downloads (AppleScript `download`): `NSAppleEventsUsageDescription` + `com.apple.security.automation.apple-events`
- Music library reading (iTunesLibrary): `NSAppleMusicUsageDescription`

To re-test the prompts during development: `tccutil reset Photos beardfm.iPod-Pro-Max` and `tccutil reset AppleEvents beardfm.iPod-Pro-Max`.

## Building

Open `Refs/SwiftUI/iPod Pro Max.xcodeproj` in Xcode 26 and run. Deployment target is macOS 15. App Sandbox is off (the app is distributed outside the Mac App Store).

From the command line (ad-hoc signed, runs locally without a Developer ID certificate):

```sh
# Debug, into the default DerivedData location
xcodebuild -project "Refs/SwiftUI/iPod Pro Max.xcodeproj" -scheme "iPod Pro Max" -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

# Release, into ./Build/Legacy/DerivedData
xcodebuild -project "Refs/SwiftUI/iPod Pro Max.xcodeproj" -scheme "iPod Pro Max" -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath Build/Legacy/DerivedData -allowProvisioningUpdates build
```

If either fails to link with undefined AVFoundation/SwiftUI symbols, DerivedData is stale — rerun with `clean build`.

Development launch arguments (Edit Scheme › Arguments):

- `-simulatedIPodFolder /path/to/folder` — treat a folder with an `iPod_Control` directory as an iPod for this launch.
- `-libraryDir /path` — use a different library folder.
- `-initialSelection music|podcasts|device`

Settings › Advanced can also create a test iPod folder without hardware.

## Portable core and command-line tool

`Package.swift` at the repository root builds the app's core for macOS, Linux and Windows: `iPodKit` (iTunesDB, ArtworkDB, PhotoDB, hash58, the sync engine; Foundation only), `MediaKit` (tags, artwork, conversions: AVFoundation on the Mac, pure Swift and ffmpeg elsewhere), `DeviceKit` (finding, watching and ejecting iPods on each OS) and the `ipodpromax` command-line tool.

```sh
swift build -c release
swift test                                   # reference tests: same bytes on every OS
.build/release/ipodpromax list
.build/release/ipodpromax sync ~/Music/Library --ipod /Volumes/IPOD
```

Details, measurements and what's left (the Xcode app consuming the package): `Docs/Architecture/Package Swift.md` and `Docs/Architecture/CLI ipodpromax.md`.

## Testing tools

- `Tools/DbTest/run.sh <samples dir> <ipod folder>` — end-to-end sync against a simulated iPod, then dumps the resulting database. Add `--read-only` to just parse an iPod folder. Diagnostic-only flags, each self-contained (no samples needed beyond what they generate/fetch themselves): `--audiobooks` (scans `<samples dir>/Audiobooks`, syncs it, prints the resulting device tracks), `--ohdio` / `--youtube` (live network smoke test of those podcast sources), `--lyrics` (ID3 fixup against `<samples dir>/song.mp3`), `--migration` (writes a fully-populated library.json, strips newer fields, confirms it still reloads).
- `Tools/GpodCheck/gpodcheck.c` — small C program that reads an iPod with [libgpod](https://sourceforge.net/projects/gtkpod/) (the reference open-source implementation) to cross-check databases written by this app. Build libgpod from source first; see the comment at the top of the file.

## Shipping

The app is signed with Developer ID and notarized, then distributed as a DMG from beard.fm (Cloudflare). Steps once the certificate is installed:

1. Product › Archive in Xcode, or `xcodebuild -project "Refs/SwiftUI/iPod Pro Max.xcodeproj" -scheme "iPod Pro Max" -configuration Release archive`.
2. Export with the Developer ID option (hardened runtime is already on).
3. `xcrun notarytool submit iPodProMax.dmg --keychain-profile <profile> --wait` and `xcrun stapler staple`.

Only an Apple Development certificate is installed on this Mac today, so local builds run but a Developer ID certificate is needed before the DMG can be distributed.

## License

MIT — see [LICENSE](../../LICENSE). iPod is a trademark of Apple Inc.; this project is not affiliated with or endorsed by Apple. The database formats were implemented from public documentation and cross-checked against libgpod (LGPL), which is used only as a development-time test oracle and is not part of the app.
