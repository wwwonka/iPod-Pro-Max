# YouTube Music Plug-in (`playlistSource`)

Credential-free `playlistSource` plug-in for iPod Pro Max. Reads public YouTube Music playlists and albums via InnerTube (`WEB_REMIX`) without requiring a Google Cloud project, API key, or Premium subscription.

## How it works

1. **URL Matching (`YouTubeMusicURL.swift`)**
   Recognizes `music.youtube.com`, `www.youtube.com`, and `m.youtube.com` playlist URLs (`?list=<id>`), `browse/VL<id>` and `browse/MPREb_<id>` URLs, `youtu.be/...?list=<id>` links, and `ytmusic:playlist:<id>` / `ytmusic:album:<id>` URIs.
2. **Dynamic InnerTube Session Bootstrap (`YTMusicTokenManager.swift`)**
   Fetches `https://music.youtube.com`, parses `ytcfg.set({...})` for `INNERTUBE_API_KEY`, `INNERTUBE_CLIENT_VERSION`, and `VISITOR_DATA` in memory only, and automatically refreshes if needed.
3. **InnerTube Browse & Continuations (`InnerTube.swift` & `YTMusicParsers.swift`)**
   Queries `POST https://music.youtube.com/youtubei/v1/browse`, parses `musicResponsiveHeaderRenderer` / `musicEditablePlaylistDetailHeaderRenderer` and `musicPlaylistShelfRenderer` / `musicShelfRenderer`, follows continuation tokens up to 100 pages (10,000 tracks max), respects HTTP `429 Retry-After`, extracts `playlistSetVideoId` for exact track occurrence identity, and computes a deterministic SHA-256 `revision` from `<title>\n<sourceID>...`.
4. **Optional Authenticated Web Session & Editing (`YouTubeMusicSource.swift`)**
   Supports macOS interactive Web sign-in (`Sign In…`), browser session import (`Import from Browser…`), or pasting a `music.youtube.com` `Cookie` header (with silent background refresh at launch on macOS). Generates `SAPISIDHASH` headers on the fly from `SAPISID` / `__Secure-3PAPISID` to support:
   - Reordering owned playlists (`source/reorder`): `browse/edit_playlist` (`ACTION_MOVE_VIDEO_BEFORE`) using `setVideoId`.
   - Searching & adding tracks (`source/addTracks`): bounded parallel search (up to 4 workers) via `youtubei/v1/search` (`Songs` filter + fallback) and `ACTION_ADD_VIDEO`.
   - Removing exact track occurrences (`source/removeTracks`): `ACTION_REMOVE_VIDEO` using `(videoId, setVideoId)`.
   - Renaming playlists (`source/rename`): `ACTION_SET_PLAYLIST_NAME`.
   - Creating playlists (`source/createPlaylist`): `youtubei/v1/playlist/create`.
   - Uploading custom playlist artwork (`source/setArtwork`): 2-step Scotty resumable upload to `/playlist_image_upload/playlist_custom_thumbnail` followed by `ACTION_SET_CUSTOM_THUMBNAIL` (requires phone-verified YouTube account per Google's rules).

## Build & Test

```bash
swift build --product YouTubeMusicPlugin
mkdir -p Plug-ins/YouTubeMusic/bin/macos
cp .build/debug/YouTubeMusicPlugin Plug-ins/YouTubeMusic/bin/macos/youtube-music-plugin
swift run ipodpromax plugin test Plug-ins/YouTubeMusic --offline
```
