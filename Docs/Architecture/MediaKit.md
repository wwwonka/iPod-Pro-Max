# MediaKit

Tout ce qui touche aux fichiers média, derrière trois protocoles. **Sur Mac, on garde les chemins rapides actuels.** Sur Windows et Linux, on utilise des implémentations portables.

```swift
protocol TagReader: Sendable      { func read(_ url: URL) async throws -> TrackMetadata }
protocol ArtworkCodec: Sendable   { func decode(_ data: Data, maxSide: Int) throws -> PixelBuffer }
protocol Transcoder: Sendable     { func toAAC(...) ; func toIPodVideo(...) ; func muxAudiobook(...) }
```

| | Mac (`MediaKitApple`) | Windows / Linux (`MediaKitPortable`) |
|---|---|---|
| Tags | AVFoundation (`MetadataExtractor` actuel) | Lecteur en Swift pur : ID3v2, atomes MP4, FLAC/Vorbis comments. On étend `BinaryIO` et `LyricsTagFixup`. |
| Pochettes | ImageIO (décodage + réduction) | ffmpeg `-f rawvideo -pix_fmt rgb565le`, un processus par pochette unique. La déduplication `ArtworkKeyCache` limite à environ 1 appel pour 10 pistes. |
| Audio | AVFoundation (`Transcoder`) | ffmpeg (`aac`) |
| Vidéo | VideoToolbox (`VideoTranscoder`) | ffmpeg avec encodeur matériel si disponible (nvenc, qsv, vaapi), sinon libx264 |
| Livres audio | ffmpeg (déjà le cas) | ffmpeg |

## Pourquoi pas ffmpeg partout
Lancer un `ffprobe` par fichier sur 5 299 fichiers ferait exploser les 8,7 s d'import. Le lecteur de tags en Swift pur est aussi rapide qu'AVFoundation : il lit quelques Ko en tête de fichier. On le valide avec `dbtest --import-bench` en le comparant à AVFoundation sur la même bibliothèque.

## Encodage pour l'iPod (iPodKit)
L'encodage RGB565, UYVY et I420 des pochettes et photos se fait en Swift pur dans iPodKit, à partir d'un `PixelBuffer`. Il ne dépend donc pas de l'OS.

## Outils externes
ffmpeg et yt-dlp sont embarqués par OS dans `Tools/` sur l'iPod (voir [[Sur l'iPod]]). Ils remplacent la recherche actuelle dans `/opt/homebrew/bin`. yt-dlp se met à jour lui-même (`-U`) quand l'ordi a du réseau. Voir [[Risques]].

## Mise en œuvre (2026-10-30)
Une seule cible `MediaKit` ; les fichiers AVFoundation sont sous `#if canImport(AVFoundation)` (voir [[ADR-006 Noyau portable sans dépendance Apple]]).

| Rôle | Mac | Linux, Windows |
|---|---|---|
| Tags (`MetadataExtractor.extract`) | `AVTagReader` (AVFoundation, inchangé) | `PortableTagReader` : ID3v1, ID3v2.2–2.4 (désynchronisation, UTF-16, APIC, USLT) et en-têtes MP3 (Xing/Info, VBRI, sinon débit constant ou comptage des trames), atomes MP4, FLAC (STREAMINFO, Vorbis comments, PICTURE), Ogg Vorbis et Opus, WAV (+ LIST INFO, `id3 `), AIFF (+ `ID3 `) |
| Décodage d'images (`ImageLoading.pixels`) | ImageIO | swift-image-formats (JPEG Swift pur, libpng, libwebp) |
| JPEG des pochettes (`ImageLoading.jpegData`) | ImageIO | swift-image-formats |
| Audio vers AAC | `Transcoder` (AVFoundation) | `FFmpegTranscoder` (aac 256 kbit/s) |
| Vidéo pour l'iPod | `VideoTranscoder` (VideoToolbox) | `FFmpegTranscoder` (premier encodeur H.264 disponible, Baseline, 320×240 max) |
| Infos et image d'une vidéo | AVFoundation | `ffmpeg -i`, sans ffprobe |
| Livres audio en plusieurs fichiers | ffmpeg | ffmpeg |

ffmpeg n'est jamais celui du système : c'est le nôtre, livré avec l'app ([[ffmpeg embarqué]]).

`MediaServices` répond aux besoins de `SyncEngine` (`SyncMediaServices`) avec la bonne implémentation selon l'OS. `FolderImporter` lit un dossier entier en parallèle (CLI et prototype). Recherche de ffmpeg : voir [[CLI ipodpromax]].

Mesures et comparaison avec AVFoundation : voir [[Package Swift]].
