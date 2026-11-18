# Plug-ins : architecture et guide pour les agents

Décision : [[ADR-007 Plug-ins hors processus]]. Contrat de référence : [[feature-plugins]].

Chaque service externe (Spotify, Soulseek, yt-dlp, YouTube Music, Deezer…) est un exécutable séparé qui dialogue avec l'application en **JSON-RPC 2.0** (un message JSON UTF-8 par ligne) sur `stdin`/`stdout`. L'application n'embarque aucune logique propre à un service : le cœur (`PluginKit` et les moteurs applicatifs) ne connaît que des **rôles** indépendants.

## Composants dans `Sources/PluginKit/`

| Fichier | Rôle |
|---|---|
| `Types.swift` | Rôles (`PluginRole`), `TrackRef`, `Playlist`, `Candidate`, `Availability`, `QualityPolicy`, `ShareIndexEntry`, erreurs et valeurs JSON. |
| `Protocols.swift` | Protocoles Swift par rôle (`PlaylistSource`, `PlaylistReorderable`, `PlaylistEditable`, `Resolver`, `Downloader`, `ShareProvider`, `MetadataLookupProvider`, `LyricsLookupProvider`) et protocoles optionnels (`PluginConfigurable`, `PluginAccountHandling`, `PluginActionHandling`). |
| `MetadataFinder.swift`, `LyricsProvider.swift` | Fournisseurs intégrés déplacés de MediaKit (MusicBrainz, AcoustID, iTunes, LRCLIB, Musixmatch). |
| `PluginMain.swift` | Boucle JSON-RPC côté plug-in (`PluginMain.run(roles:)`), gestion de `$/cancelRequest`, limitation de `$/progress` (≤ 4/s), arrêt automatique à la fermeture de `stdin`. |
| `ExternalPlugin.swift` | Adaptateur côté app, conforme à tous les protocoles de rôle, avec partage de processus entre opérations concurrentes, `shutdown` sans minuteur d'inactivité et suivi des plantages (3 en 60 s → état Error). |
| `Manifest.swift`, `SVGPath.swift` | Lecture et validation de `plugin.json`, sélection de l'exécutable par OS/architecture, validation du badge SVG à un seul tracé (`M`, `L`, `C`, `Z`). |
| `PluginPackage.swift`, `ZipArchive.swift` | Vérification et création de paquets `.ippmplugin` (archive ZIP + `SHA256SUMS` en Swift pur). |
| `PluginRegistry.swift`, `SafeStorage.swift` | Découverte dans `Plug-ins/` et dossiers non empaquetés, `plugins.json`, réglages/secrets atomiques avec `.bak`, installation et suppression atomiques. |
| `PluginCLI.swift` | Moteur des commandes `ipodpromax plugin new|test|pack|install`. |

## Règles de portabilité (obligatoires)

Un plug-in compile et tourne sur **macOS, Windows et Linux** :
- importer uniquement `Foundation` et `PluginKit` (plus éventuellement une cible C portable isolée pour le réseau bas niveau) ;
- **interdits** : `Network.framework`, `Combine`, `os.Logger`, `CryptoKit` (utiliser `PluginKit.SHA256`), `Compression`, `AppKit` ;
- écrire les journaux bruts uniquement sur `stderr` ou via `$/log` — **jamais sur `stdout`**, réservé aux messages JSON-RPC ;
- `PluginMain.run(roles:)` s'arrête dès que `stdin` se ferme (EOF) pour ne laisser aucun processus orphelin.

## Marche à suivre pour ajouter un plug-in

Un agent qui écrit un nouveau plug-in ne touche **ni au moteur d'abonnements, ni aux Préférences, ni aux autres plug-ins** :

1. **Créer le squelette** :
   ```sh
   swift run ipodpromax plugin new Deezer --role playlistSource
   ```
   Crée `Plug-ins/Deezer/` avec `plugin.json`, `Sources/DeezerPlugin/main.swift`, `DeezerHandler.swift`, `badge.svg`, `README.md` et `Tests/fixtures.json`.
2. **Implémenter le rôle** (en s'inspirant de `Plug-ins/Spotify/` pour les sources) :
   - conformer le gestionnaire aux protocoles nécessaires (`PlaylistSource`, `Resolver`, `Downloader`, `ShareProvider`, `PluginConfigurable`, `PluginAccountHandling`, `PluginActionHandling`) ;
   - vérifier `Task.checkCancellation()` pendant les appels longs pour répondre `cancelled` en moins de 2 s ;
   - pour un `PlaylistSource`, calculer une `Playlist.revision` déterministe (par exemple `SHA256` du titre + `sourceID` ordonnés).
3. **Déclarer `urlPatterns` et `badge.svg`** dans `plugin.json` :
   - `urlPatterns` : expressions régulières testées sur l'URL sans lancer de processus ;
   - `badge.svg` : monochrome, boîte carrée (`viewBox="0 0 N N"`), **un seul `<path>`** avec commandes `M`, `L`, `C`, `Z` uniquement (lisible par `CustomSymbol`).
4. **Renseigner `Tests/fixtures.json`** avec des entrées d'exemple et, si possible, des réponses enregistrées pour `--offline`.
5. **Ajouter la cible exécutable au `Package.swift` racine** (dépendant uniquement de `"PluginKit"`), puis compiler et vérifier :
   ```sh
   swift build --product DeezerPlugin
   mkdir -p Plug-ins/Deezer/bin/macos
   cp .build/debug/DeezerPlugin Plug-ins/Deezer/bin/macos/deezer-plugin
   swift run ipodpromax plugin test Plug-ins/Deezer --offline
   ```
   `plugin test` vérifie dans l'ordre :
   1. manifeste valide ;
   2. exécutable présent pour l'OS courant ;
   3. `initialize` en moins de 10 s ;
   4. appel de chaque rôle déclaré avec `Tests/fixtures.json` ;
   5. annulation (`$/cancelRequest`) renvoyant `cancelled` en moins de 2 s ;
   6. `badge.svg` lisible par `SVGBadgeParser` / `CustomSymbol` ;
   7. `shutdown` propre (code de sortie 0) ;
   8. arrêt du processus lorsque `stdin` se ferme.
6. **Empaqueter** pour distribution ou **laisser dans `Plug-ins/`** si le plug-in est fourni avec l'app (`Tools/Build/build.sh` et `assemble-ipod.sh` compilent et installent automatiquement les cibles présentes sous `Plug-ins/` dans `Build/iPod Pro Max/Plug-ins/`) :
   ```sh
   swift run ipodpromax plugin pack Plug-ins/Deezer
   swift run ipodpromax plugin install Deezer-1.0.0.ippmplugin
   ```

## Annexe A : protocole JSON-RPC 2.0

Transport : **une ligne JSON UTF-8 terminée par `\n` par message**, sur `stdin` (app → plug-in) et `stdout` (plug-in → app). Taille maximale d'une ligne : **16 Mio** (`messageTooLarge` au-delà).

| Méthode | Sens | Paramètres → résultat |
| --- | --- | --- |
| `initialize` | app → plug-in | `{apiVersion, host:{os, arch, appVersion, onIPod}, paths:{data, cache, temp, ffmpeg}, settings, config}` → `{roles, version}` |
| `shutdown` | app → plug-in | `{}` → `{}` |
| `settings/changed` | notification app → plug-in | `{settings}` |
| `account/login` | app → plug-in | `{key, fields}` → `{status, displayName}` ou `{openURL}` (OAuth ; résultat final via `account/status`) |
| `account/logout`, `account/status` | app → plug-in | `{}` → `{status, displayName?}` |
| `action/<key>` | app → plug-in | `{}` → `{message?}` |
| `source/fetch` | app → plug-in | `{url}` → `{playlist: Playlist, tracks: [TrackRef]}` |
| `source/reorder` | app → plug-in | `PlaylistReorderRequest` → `{}` (optionnel, `PlaylistReorderable`) |
| `source/addTracks` | app → plug-in | `PlaylistAddTracksRequest` → `{added, notFoundTitles}` (optionnel, `PlaylistEditable`) |
| `resolver/search` | app → plug-in | `{track: TrackRef, policy}` → `{candidates}` (liste finale) ; partiels via notification `resolver/candidates` `{requestID, candidates}` |
| `downloader/download` | app → plug-in | `{candidate, destinationDir}` → `{path}` |
| `share/setIndex` | app → plug-in | `{part, lastPart, entries:[{virtualPath, realPath, size, bitrateKbps?, durationMs?}], uploadSlots}` → `{}` |
| `share/stop` | app → plug-in | `{}` → `{}` |
| `metadata/search` | app → plug-in | `MetadataQuery` → `{matches: [MetadataMatch]}` |
| `lyrics/fetch` | app → plug-in | `LyricsQuery` → `{match: LyricsMatch?}` |
| `$/cancelRequest` | notification app → plug-in | `{id}` |
| `$/progress` | notification plug-in → app | `{requestID, done, total?, message?}` (au plus 4/s par requête) |
| `$/log` | notification plug-in → app | `{level: "debug"/"info"/"warning"/"error", message}` |
| `$/status` | notification plug-in → app | `{state: "connecting"/"ready"/"error", message?}` |

`share/setIndex` est découpé en morceaux d'au plus **5 000 entrées** (`part` numéroté à partir de 0, `lastPart: true` sur le dernier).

Codes d'erreur (`error.data.code`) :
`cancelled`, `notFound`, `unauthorized`, `rateLimited` (avec `retryAfterSeconds`), `network`, `apiChanged`, `unsupported`, `wrongResolver`, `internal`.
Le champ `error.message` est en anglais et peut être affiché tel quel dans l'interface.

## Annexe B : manifeste `plugin.json` et paquet `.ippmplugin`

Champs obligatoires : `id` (`[a-z0-9-]+`, identique au nom du dossier installé), `name`, `version`, `apiVersion` (`1`), `description`, `roles`, `executable` (`macos`, `windows-x64`, `windows-arm64`, `linux-x86_64`, `linux-aarch64`).

Champs optionnels : `author`, `license`, `serviceName`, `urlPatterns`, `badge`, `requiresConsent` (`"p2p"` ou `"scraping"`), `settings`, `config`.

Types de réglages supportés par les Préférences : `bool`, `string`, `secret`, `int` (`min`, `max`, `unit`), `enum` (`options: [{value, label}]`), `orderedList` (`options`), `folder` (`default: "downloads"`), `account` (`fields`, `oauth`, `autoIdentity`), `action` (`label`), `note` (`text`). Chaque réglage accepte `help` et `visibleIf: {key, equals}`.

Un fichier `.ippmplugin` est une archive ZIP contenant `plugin.json`, `bin/`, `SHA256SUMS` (couvrant tous les autres fichiers) et optionnellement `vendor/`, `badge.svg`, `LICENSE`, `README.md`.
