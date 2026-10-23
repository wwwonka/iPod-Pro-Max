# Modules

Un seul `Package.swift` remplace progressivement le projet Xcode comme source de vérité du code. L'app Mac actuelle continue à se compiler pendant toute la transition. Voir [[Compilation multiplateforme]].

```
Package.swift
├─ iPodKit        Swift pur : iTunesDB, ArtworkDB, PhotoDB, PlayCounts, Hash58 (swift-crypto),
│                  SyncEngine, modèle du manifeste
├─ MediaKit       protocoles TagReader / ArtworkCodec / Transcoder
│   ├─ MediaKitApple     AVFoundation + ImageIO + VideoToolbox
│   └─ MediaKitPortable  tags en Swift pur + ffmpeg embarqué
├─ DeviceKit      détection, identification et éjection d'iPod, par OS
├─ AppModel       état observable partagé (LibraryStore, SyncCoordinator, DeviceStore…)
├─ AppUI          vues SwiftCrossUI uniques + MacTheme.css
└─ App            exécutable ; choix du backend ; intégrations Mac (#if os(macOS))
```

## D'où vient chaque morceau

| Module | Fichiers actuels | Travail |
|---|---|---|
| iPodKit | `Core/*`, `Sync/SyncEngine.swift`, `Device/IPodModelTable.swift`, `Device/IPodDevice.swift` | CryptoKit → swift-crypto (`Insecure.SHA1` existe aussi). `CGImage` → tampon de pixels. Les Core sans dépendance Apple bougent tels quels. |
| MediaKit | `Library/MetadataExtractor`, `Transcoder`, `VideoTranscoder`, `AudiobookMuxer`, `FFmpeg`, `LyricsTagFixup` | Mettre derrière des protocoles. Voir [[MediaKit]]. |
| DeviceKit | `Device/DeviceMonitor`, `Device/USBIdentification` | Une implémentation par OS. Voir [[DeviceKit]]. |
| AppModel | `Library/LibraryStore`, `Sync/SyncCoordinator`, `Library/*Feed`, `ArtistPhotos`, la logique de `ContentView` et `MusicView` | Retirer AppKit. `OSAllocatedUnfairLock` → `Synchronization.Mutex`. Chemins des données via [[Sur l'hôte]] et [[Sur l'iPod]]. |
| AppUI | `UI/*`, `ContentView`, `iPod_Pro_MaxApp` | Réécriture en SwiftCrossUI. Voir [[Un code, look Mac partout]]. |
| App (Mac seulement) | `MusicAppImporter` (iTunesLibrary), `PhotosAccess` (Photos) | Gardés derrière `#if os(macOS)`. |

## Règles
- **iPodKit ne dépend de rien d'Apple.** La CI Linux le prouve à chaque commit (voir [[CI et packaging]]).
- **Le Mac ne descend jamais au plus petit dénominateur commun.** Ses chemins rapides restent derrière les protocoles de [[MediaKit]].
- **AppModel ne connaît pas l'interface.** Tri, sélection, regroupement et progression y vivent, pour que les vues restent minces.
- **L'état partagé entre tâches** passe par `Mutex` ou un acteur, jamais par le main actor.
