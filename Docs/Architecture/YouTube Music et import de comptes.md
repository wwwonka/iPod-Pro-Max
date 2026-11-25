# YouTube Music et import de comptes musicaux

Décisions associées : [[Plug-ins]], [[feature-playlist-subscriptions]], [[feature-plugin-spotify]], [[ADR-007 Plug-ins hors processus]].

Ce document décrit l'architecture du plug-in **YouTube Music** (`youtube-music`), l'import direct des playlists depuis un compte connecté (`PlaylistBrowsable`), l'identification exacte des versions vidéo sur YouTube Music, ainsi que les mécanismes de robustesse réseau et de persistance de session pour **Spotify** et **YouTube Music**.

## 1. Plug-in YouTube Music (`Plug-ins/YouTubeMusic/`)

Le plug-in dialogue sans clé Google Cloud ni compte Premium grâce au client web InnerTube (`WEB_REMIX`) utilisé par `music.youtube.com`, compilé sur macOS, Windows et Linux :

- **`YouTubeMusicURL.swift`** : normalise les URL et URI (`music.youtube.com/playlist?list=…`, `youtube.com/playlist?list=…`, `music.youtube.com/browse/VL…` / `MPREb_…`, `youtu.be/…?list=…`, `ytmusic:playlist:…` / `ytmusic:album:…`). L'auto-playlist des titres aimés est normalisée vers `list=LM` (`browseId: VLLM`).
- **`InnerTube.swift`** :
  - extrait depuis le HTML `ytcfg.set({...})` les paramètres dynamiques (`INNERTUBE_API_KEY`, `INNERTUBE_CLIENT_VERSION`, `VISITOR_DATA`, `SESSION_INDEX`, `DELEGATED_SESSION_ID` / `DATASYNC_ID`, `LOGGED_IN`) ;
  - signe les appels authentifiés par `SAPISIDHASH` / `SAPISID1PHASH` / `SAPISID3PHASH` via `PluginKit.PluginSHA1` (`Sources/PluginKit/SHA1.swift`), sans dépendance `CryptoKit` ;
  - attache `X-Goog-AuthUser` (`authUser` ou `SESSION_INDEX`) et **`X-Goog-PageId`** + `context.user.onBehalfOfUser` lorsque le compte utilise une chaîne/identifiant délégué (`DELEGATED_SESSION_ID`). Sans `X-Goog-PageId`, InnerTube cible le profil racine sans bibliothèque YouTube.
- **`YTMusicParsers.swift`** :
  - lit les réponses JSON `browse` initiales et par continuation jusqu'à 100 pages / 10 000 pistes ;
  - extrait les playlists de compte (`FEmusic_liked_playlists`, `FEmusic_library_landing`, `VLLM` / `FEmusic_liked_videos`) et les pages HTML `music.youtube.com/library/playlists` / `/playlist?list=…` (`initialData.push(...)` avec échappements JS `\xHH`/`\uHHHH` et cartes `lockupViewModel`) ;
  - extrait le nom complet du compte (`account/account_menu`, `runs` et `simpleText`) via parcours d'arbre JSON (`extractAccountDisplayName`) plutôt que par regex ;
  - identifie si un morceau provient d'une **vidéo** (`TrackRef.isVideo`) à partir de `musicVideoType` (`MUSIC_VIDEO_TYPE_OMV`, `MUSIC_VIDEO_TYPE_UGC`, `MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC` → `true` ; `MUSIC_VIDEO_TYPE_ATV` → `false`, avec repli sur vignette vidéo `i.ytimg.com/vi/` lorsqu'il n'y a aucun album associé).
- **`YouTubeMusicSource.swift`** : implémente `PlaylistSource`, `PlaylistReorderable`, `PlaylistEditable`, `PlaylistBrowsable`, `PluginConfigurable` et `PluginAccountHandling`.
  - Édition des playlists personnelles via `/youtubei/v1/browse/edit_playlist` (`ACTION_MOVE_VIDEO_BEFORE`, `ACTION_ADD_VIDEO`, `ACTION_REMOVE_VIDEO`, `ACTION_SET_PLAYLIST_NAME`, `ACTION_SET_CUSTOM_THUMBNAIL`), création via `/youtubei/v1/playlist/create`, et téléversement de pochette en deux étapes Scotty (`/playlist_image_upload/playlist_custom_thumbnail`).
  - Sur rejet de pochette personnalisée (`403`, absence de `X-Goog-Upload-URL` ou refus `ACTION_SET_CUSTOM_THUMBNAIL`), l'erreur indique explicitement la vérification de numéro de téléphone exigée par YouTube (`youtube.com/verify`) ; côté application, l'alerte modale et la bannière proposent un bouton direct **"Verify on YouTube…"** et rétablissent la pochette précédente afin de ne pas induire l'utilisateur en erreur.

## 2. Identification et téléchargement exact des vidéos (`TrackRef.isVideo`)

Lorsqu'une piste d'une playlist YouTube Music est une vidéo non issue d'un album (`isVideo == true`), toute la chaîne de résolution préserve son identité exacte :

1. **`LibraryTrackMatcher`** (`Sources/MediaKit/Subscriptions/LibraryTrackMatcher.swift`) : vérifie uniquement l'identifiant lié ou la correspondance exacte `(source, sourceID)` (`youtube-music:<videoId>`). Il ne substitue plus un fichier album local de même titre/artiste.
2. **`SubscriptionEngine`** (`Sources/MediaKit/Subscriptions/SubscriptionEngine.swift`) : contourne `Soulseek` et route ces pistes directement vers `yt-dlp` (même si l'option globale de repli YouTube est désactivée), et les exclut des mises à niveau qualité (*Refresh*) afin qu'un album studio ne vienne jamais écraser la version vidéo téléchargée.
3. **`YtDlpHandler`** (`Plug-ins/yt-dlp/Sources/YtDlpPlugin/YtDlpHandler.swift`) : pour une piste `youtube-music`, effectue une interrogation directe `yt-dlp --dump-json --no-playlist` sur `https://www.youtube.com/watch?v=<videoId>` (pour les vidéos) ou `https://music.youtube.com/watch?v=<videoId>` avant toute recherche textuelle.
4. **`CandidateScorer`** (`Sources/MediaKit/Subscriptions/CandidateScorer.swift`) : accepte directement le candidat `yt-dlp` correspondant exactement au `sourceID` d'une piste `isVideo == true`, même si le titre YouTube contient `(Live)` ou diffère de la version album.

## 3. Navigation de compte, cache et persistance de session

- **`PlaylistBrowsable` (`source/listUserPlaylists`)** : permet à la fenêtre **Import Playlists from Account…** (`NewSubscriptionSheet.swift`, `SubscriptionController.swift`) de lister les playlists d'un compte sans copier d'URL, avec cache par plug-in lors des changements d'onglet (aucune reconstruction complète lors du basculement Spotify ↔ YouTube Music), filtrage instantané, nombre de pistes, tri déterministe (`RemotePlaylistSummary.sortedForDisplay`: *Titres aimés* en premier, puis playlists créées par l'utilisateur, puis le reste) et case optionnelle d'ajout aux **Favorites** pour les titres aimés (`SubscriptionEntry.syncFavorites`).
- **Spotify (`Plug-ins/Spotify/`)** :
  - lit la barre latérale via Pathfinder `libraryV3` (incluant `Liked Songs` / `collection-tracks`) avec repli `/v1/me/playlists` (sans sommeil `429` lors d'un simple enrichissement de compteurs) et `spclient` rootlist ;
  - persiste les hashs GraphQL découverts dans `Data/.spotify-hashes.json`, parallélise `fetchBundleHashes` (`min(6, activeProcessorCount)` workers avec arrêt anticipé) et évite tout scan bloquant des bundles JS lors d'une suppression de pistes (`removeTracks` passe directement par le delta rapide `spclient REM` si aucun hash n'est déjà en cache) ;
  - prend en charge la capture de jeton et de hashs Pathfinder depuis `SpotifyWebBridge`, le renouvellement direct par cookie `sp_dc` et le réordonnancement par mutation `spclient MOV` en secours.
- **Persistance des identifiants Web (`PluginController.swift`, `YouTubeMusicWebBridge.swift`, `SpotifyWebBridge.swift`)** :
  - `secrets.json` enregistre immédiatement l'ensemble des champs utiles (`sp_dc`, `username`, `clientToken`, `displayName` côté Spotify ; `cookie`, `authUser`, `delegatedSessionID`, `displayName` côté YouTube Music), réinjectés dès le démarrage (`restoreSavedWebSessionIfMissing`) si le plug-in redémarre déconnecté ;
  - `YouTubeMusicWebBridge.signInInteractively` nettoie les données WebKit `google` et `youtube` avant de charger `accounts.google.com` afin d'éviter les conflits `CheckCookie` (*"problem with your cookie settings"*), tandis que `seedCookies` n'injecte plus que sur `.youtube.com` et que le refresh silencieux vérifie `LOGGED_IN == true` sans écraser une session existante ;
  - `RegistryPluginHost.fetchPlaylist` dispose d'un rappel `onUnauthorized` pour rafraîchir automatiquement la session Web lors d'une synchronisation si une playlist privée renvoie `loggedOut: true`.
