# Package Swift

Le noyau d'iPod Pro Max est un package Swift à la racine du repo (`Package.swift`). Il se compile et ses tests passent **sur macOS, Linux et Windows** avec `swift build` et `swift test`. C'est la réalisation des phases 1 et 4 de [[Phases]] côté code ; le plan d'origine est dans [[Modules]].

> Mis en place le 2026-10-29/30. L'app SwiftUI (projet Xcode) consomme ce package depuis le 2026-10-30.

## Application principale

Depuis la promotion du 2026-10-30, ce package contient aussi `iPodProMaxApp`, l’application SwiftCrossUI dans `iPod Pro Max/`. Utiliser `Tools/Build/build.sh` pour appliquer les correctifs du framework avant de compiler. `swift build --product ipodpromax` reste la commande de compilation de la CLI. Le projet Xcode de référence est dans `Refs/SwiftUI/`.

## Les cibles

```
Package.swift            swift-tools-version 6.0, mode de langage Swift 5 (comme l'app)
├─ iPodProMaxApp        interface SwiftCrossUI → iPodKit, DeviceKit, DefaultBackend
├─ iPodKit              Foundation seulement
├─ MediaKit             → iPodKit (+ swift-image-formats hors Mac)
├─ CWinDevices          C, Windows seulement (cfgmgr32)
├─ DeviceKit            → iPodKit (+ CWinDevices sous Windows)
├─ ipodpromax           exécutable, → les trois bibliothèques (voir [[CLI ipodpromax]])
├─ iPodKitTests         tests de référence
└─ MediaKitTests
```

| Cible | Contenu | D'où ça vient |
|---|---|---|
| **iPodKit** | iTunesDB (lecture, écriture), ArtworkDB, PhotoDB, Play Counts, hash58, `SyncEngine`, `IPodDevice`, table des modèles, modèles de bibliothèque (`LibraryTrack`, `DeviceSyncRecord`…), `LyricsTagFixup` | `Core/*`, `Sync/SyncEngine.swift`, `Device/IPodDevice.swift`, `Device/IPodModelTable.swift`, `Library/LibraryModels.swift`, `Library/LyricsTagFixup.swift` (déplacés avec `git mv`) |
| | Nouveau : `SHA1`, `PixelBuffer` et `RGB565`, `SyncServices` (protocoles injectés dans la sync), `FileOps`, `DeviceDataFolder`, `USBDeviceIdentity` | |
| **MediaKit** | `MetadataExtractor` (façade), `PortableTagReader`, `AVTagReader`, `ImageLoading`, `FFmpeg`, `FFmpegTranscoder`, `Transcoder` et `VideoTranscoder` (AVFoundation), `AudiobookMuxer`, `MediaServices`, `FolderImporter` | `Library/MetadataExtractor`, `Transcoder`, `VideoTranscoder`, `AudiobookMuxer`, `FFmpeg` |
| **DeviceKit** | `DeviceScanner`, `USBIdentification`, `VolumeWatcher`, `Ejector`, une implémentation par OS | `Device/USBIdentification.swift` (Mac) ; Linux et Windows nouveaux |

Les détails par module : [[MediaKit]], [[DeviceKit]].

## Ce qui a changé pour ne plus dépendre d'Apple

| Avant | Maintenant | Pourquoi |
|---|---|---|
| `CryptoKit.Insecure.SHA1` dans hash58 | `SHA1` en Swift pur (iPodKit) | Pas de swift-crypto (BoringSSL, long à compiler sous Windows ARM) pour un seul hash par sync. Testé égal à CryptoKit sur Mac. |
| `CGContext` pour mettre les pochettes et photos à l'échelle | `PixelBuffer.fitted` / `resized` : filtre triangle séparable, élargi en réduction (moyenne de surface), **poids entiers** | Résultat identique à l'octet près sur les 3 OS. Mêmes dimensions et marges qu'avant (même arrondi). |
| `ImageIO` dans iPodKit | Décodage dans MediaKit (`ImageLoading`) : ImageIO sur Mac, swift-image-formats ailleurs ; l'échelle reste dans iPodKit | iPodKit ne décode rien lui-même. |
| `SyncEngine` appelait `Transcoder`, `VideoTranscoder`, `AudiobookMuxer`, `PhotosAccess` | `SyncRequest.media: any SyncMediaServices` et `SyncRequest.photoLibrary: (any PhotoLibrarySource)?` | La sync ne sait pas sur quel OS elle tourne. Photos (Mac) se branche comme source optionnelle. |
| `FileManager.replaceItemAt` pour l'iTunesDB | `FileOps.writeReplacing` : écrit à côté, `fsync`, puis `rename` (POSIX) ou `MoveFileExW` (Windows) | `replaceItemAt` n'existe pas partout ; FAT32 n'a pas de journal. |
| Capacité du volume par `URLResourceKey` | `FileOps.volumeCapacity` (`attributesOfFileSystem` hors Mac) | Clés indisponibles sur Linux et Windows. |
| `SortKey.collate` avec `locale: .current` | `locale: nil` | Même bibliothèque, même iTunesDB sur tous les ordis (le « i » turc changeait l'ordre). |
| `IPodDevice.detect` appelait IOKit | Paramètre `usbLookup`, fourni par DeviceKit | iPodKit reste pur. |
| FireWire GUID seulement depuis SysInfo | Repli sur le **numéro de série USB** quand il fait 16 chiffres hexadécimaux | Sans SysInfoExtended, hash58 était impossible sur classic et nano 3G/4G (voir [[DeviceKit]]). |

Les types publics des modules ont reçu `public`, des `init` publics (l'init membre à membre implicite est `internal`) et `Sendable`. Le rendu des pochettes pendant la sync est maintenant **parallèle**, une pochette par cœur, par lots pour limiter la mémoire, comme le demande `AGENTS.md`.

## Compiler et tester

```sh
swift build -c release          # les trois bibliothèques et ipodpromax
swift test                      # 14 tests
```

- **macOS** : Xcode 16.4 (Swift 6.1), cible macOS 15 comme l'app.
- **Linux** (Fedora 44 aarch64, VM Parallels) : `swift-lang` 6.3.2 de Fedora. ffmpeg-free pour les conversions.
- **Windows 11** (ARM64, VM Parallels) : Swift 6.4.1 et Visual Studio Build Tools installés pour le prototype. `swift build --build-system native`.

Les VM compilent dans une copie locale (`~/dev/ipodpromax`, `C:\dev\ipodpromax`), comme le prototype : compiler sur le partage Parallels est lent. Sous Windows, le build est lancé détaché (une session `prlctl exec` longue est coupée), voir `Tools/Build/build.sh` pour le même principe.

### Tests de référence
`Tests/iPodKitTests/ReferenceTests.swift` vérifie des empreintes SHA-1 enregistrées sur Mac, avec des entrées fixes (identifiants, dates, fuseau, aucun aléa) :
- iTunesDB non signé et signé hash58 (FireWire GUID fixe) ;
- signature hash58 seule ;
- vignettes ArtworkDB 56×56 et 320×320 ;
- vignettes de photos dans tous les formats classic et 5G (RGB565, UYVY, I420).

**Résultat : identiques octet pour octet sur macOS, Linux et Windows** (2026-10-30). C'était le critère de sortie de la phase 1. `IPODKIT_PRINT_REFERENCES=1 swift test --filter testPrintReferences` réimprime les valeurs, à ne mettre à jour que pour un changement voulu de la sortie.

## Mesures

Bibliothèque « Music Library » (5 300 fichiers : MP3, M4A, FLAC), Mac M-series 10 cœurs, lecture des tags en parallèle (`ipodpromax tags --bench <dossier>`) :

| Lecteur | Temps | Lus |
|---|---|---|
| AVFoundation (`AVTagReader`) | 1,79 s | 5 299 |
| Swift pur (`PortableTagReader`) | **0,50 s** | 5 300 |

Comparaison champ par champ sur ces 5 300 fichiers : le lecteur portable n'a **jamais moins** d'information qu'AVFoundation. Il en a plus sur environ 230 fichiers : AVFoundation ignore une partie du tag ID3 de certains MP3 (piste, année, artiste de l'album, paroles), par exemple quand une pochette de près de 1 Mo se trouve au milieu du tag. Les durées concordent à moins d'une seconde, sauf sur 4 MP3 VBR sans en-tête Xing, où AVFoundation se trompe : 603 s annoncées pour un fichier qui en fait 222 (8 515 trames comptées).

Sync de test (47 pistes de 4 albums, dont 12 FLAC à convertir, vers un iPod simulé) :

| OS | Lecture du dossier | Sync complète | Deuxième sync |
|---|---|---|---|
| macOS | 0,1 s | 16 s (AVFoundation pour le FLAC) | 0 copie, 0,25 s |
| Linux | 0,3 s | 57 s (ffmpeg, sources sur le partage Parallels) | 0 copie |
| Windows (ARM, ffmpeg x64 émulé) | 0,2 s | 125 s, conversions comprises | 0 copie, 1,2 s |

## Revue de code (2026-10-30)
Corrigé après la revue du package, du CLI et du prototype :
- **Identifiant d'iPod stable** : le FireWire GUID repris du numéro de série USB servait aussi d'identifiant ; pour un iPod déjà synchronisé, l'enregistrement de sync n'était plus retrouvé et toute la bibliothèque aurait été recopiée. Il ne sert plus qu'à signer la base.
- **`--ipod`** : chemins comparés après normalisation (liens, séparateur final, casse sous Windows) ; `eject` sur un dossier simulé le dit au lieu d'annoncer une éjection.
- **ffmpeg** trouvé à côté de l'exécutable même lancé depuis le `PATH` ; chaque encodeur H.264 listé est essayé tour à tour (nvenc sans carte NVIDIA, VA-API sans GPU dans une VM), celui qui marche est retenu ; VA-API reçoit `hwupload`. Vérifié sous Linux : repli sur libopenh264, fichier Baseline 320×180.
- **Une seule réencodage de pochette par album**, même quand toutes ses pistes sont lues en parallèle (AGENTS.md).
- **Lecteur de tags** : plus de dépassement d'entier sur un atome MP4 abîmé (le scan entier plantait) ; débit Vorbis lu signé.
- **DeviceKit** : `stop()` du watcher Mac attend les rappels en file ; le watcher Linux ferme son tube en cas d'échec ; sous Windows, plus de boîte « Aucun disque » en sondant un lecteur de cartes vide (aussi dans le prototype).
- **SHA-1** : tampon de travail sur la pile au lieu d'une allocation par bloc de 64 octets.
- **Prototype** : chansons triées sans casse ni accents comme la liste d'artistes ; « Unknown Artist / Album » au lieu de libellés français dans une interface anglaise ; plus de promesse de sélection multiple (⌘-clic) dans la liste d'artistes qui ne l'a pas ; symboles GTK réécrits seulement quand ils changent (pas à chaque image du glissement) ; journal Windows `%TEMP%\ippm.log` remis à zéro au-delà de 1 Mo.

Constaté et laissé ouvert :
- Prototype Windows : la liste d'artistes crée un élément XAML par artiste (pas virtualisée, contrairement à ce que dit son commentaire), comme le tableau des pistes ; même cause (`itemsSource` refuse le vecteur Swift), à régler ensemble.
- Annuler une sync avant le lancement de ffmpeg n'arrête pas cette conversion-là.

## L'app SwiftUI sur le package
Le projet Xcode référence le package local (la racine du repo) et lie iPodKit, MediaKit et DeviceKit. L'app ne garde que ce qui est à elle :
- interface SwiftUI, `LibraryStore`, `SyncCoordinator`, flux de podcasts, import depuis Musique ;
- `PhotosAccess`, branché sur la sync par `PhotosLibrary: PhotoLibrarySource` ;
- `DeviceMonitor`, qui passe maintenant par DeviceKit (`DeviceScanner`, `VolumeWatcher`, `Ejector`) : même détection que le CLI, avec le repli USB pour le modèle et le FireWire GUID ; plus d'AppKit pour les montages et l'éjection.

`Tools/DbTest/run.sh` compile le package avec `swift build` et lie le harnais aux modules : la sync de bout en bout (MP3, Apple Lossless, FLAC → AAC, WAV, vidéos, pochettes, playlists, compteurs de lecture, deuxième sync sans copie) repasse.

C'est une étape de transition : à terme, l'app multiplateforme (SwiftCrossUI) remplace l'app SwiftUI et le projet Xcode disparaît ; Xcode ouvre directement `Package.swift`.

## Ce qui reste
- **Le prototype SwiftCrossUI** doit afficher les vrais iPods (`DeviceScanner`, `VolumeWatcher`) et proposer la sync d'un dossier (`FolderImporter` + `SyncEngine`).
- Conversions en parallèle avant la copie : la sync convertit encore une piste à la fois.
- Test avec un vrai iPod sous Linux et Windows : numéro de série USB, éjection, événements de montage (seule la partie sans matériel a pu être testée dans les VM).
- CI GitHub Actions sur les 3 OS (voir [[CI et packaging]]).

Voir aussi [[ADR-006 Noyau portable sans dépendance Apple]].
