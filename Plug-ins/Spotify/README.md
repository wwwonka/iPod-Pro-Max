# Spotify Plug-in (`playlistSource`)

Credential-free `playlistSource` plug-in for iPod Pro Max. Reads public Spotify playlists and albums without requiring a Spotify Developer application, Client ID, or Premium account.

## How it works

1. **URL Matching (`SpotifyURL.swift`)**
   Recognizes `open.spotify.com` and `play.spotify.com` URLs (with or without `https://`, optional `/embed/` and `/intl-<lang>/` path prefixes, optional query parameters `?si=…`) as well as `spotify:playlist:<id>` and `spotify:album:<id>` URIs where `<id>` is 22 base-62 characters (`[0-9A-Za-z]`).
2. **Anonymous Session Bootstrap (`TokenManager.swift`)**
   Fetches the lightweight Spotify embed HTML page (`https://open.spotify.com/embed/playlist/<id>`), extracts `<script id="__NEXT_DATA__">`, and reads the short-lived anonymous access token into memory only. Refreshes when under 60 seconds remain before expiry, coalescing concurrent boots to a single request.
3. **Pathfinder GraphQL Queries (`Pathfinder.swift` & `Parsers.swift`)**
   Queries `https://api-partner.spotify.com/pathfinder/v1/query` with persisted query hashes (`fetchPlaylist` pages of 100, `getAlbum` pages of 50), paginates sequentially up to 100 pages (10,000 tracks max), respects HTTP `429 Retry-After`, retries HTTP `401` once, and computes a deterministic SHA-256 `revision` from `<title>\n<sourceID>...`.
4. **Optional Authenticated Web Session & Editing (`SpotifySource.swift`)**
   Supports interactive Web sign-in (`Sign In…`), macOS cookie import from installed browsers (`Import from Browser…` via `BrowserCookieImporter.swift`), or pasting `sp_dc`. Once signed in, the plug-in supports reading private playlists, reordering owned playlists (`PlaylistReorderable` via Pathfinder `moveItemsInPlaylist` v2/v1 with `PUT /v1/playlists/{id}/items` fallback), and searching + adding personal library tracks (`PlaylistEditable` via `/v1/search` and `POST /v1/playlists/{id}/items` or `/tracks`). Non-owned playlists return HTTP 403 and stay local-only.

## Updating rotated Spotify Pathfinder hashes

Spotify periodically rotates its GraphQL persisted-query `sha256Hash` values. When this happens, the plug-in reports `"Spotify changed how it works. Update the Spotify plug-in."` without crashing or needing a recompile.

To find the current hash from any desktop browser:

1. Open [open.spotify.com](https://open.spotify.com) and open Developer Tools (`⌥⌘I` on macOS, `Ctrl+Shift+I` elsewhere).
2. Select the **Network** tab and filter requests by `pathfinder`.
3. Open any public playlist (`fetchPlaylist`), album (`getAlbum`), or drag-reorder an owned playlist (`moveItemsInPlaylist`).
4. Click the matching `query` request and inspect the URL query parameter `extensions` (URL-decoded):
   ```json
   {"persistedQuery":{"version":1,"sha256Hash":"<new-64-char-hex-hash>"}}
   ```
5. Paste the updated hash into `plugin.json` under `config.pathfinder.fetchPlaylist.sha256`, `getAlbum.sha256`, or `moveItemsInPlaylist.sha256`.

## Build & Test

```bash
swift build --product SpotifyPlugin
mkdir -p Plug-ins/Spotify/bin/macos
cp .build/debug/SpotifyPlugin Plug-ins/Spotify/bin/macos/spotify-plugin
swift run ipodpromax plugin test Plug-ins/Spotify --offline
```
