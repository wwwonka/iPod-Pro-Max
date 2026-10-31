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

## État (2026-10-30)

L’application principale est désormais la cible `iPodProMaxApp`, avec ses sources dans `iPod Pro Max/` (App, UI, Library, Platforms, Resources). Le package racine réunit cette cible, les trois bibliothèques et la CLI. AppModel et AppUI ci-dessus restent des propositions historiques, pas des cibles existantes. L’ancienne application SwiftUI est dans `Refs/SwiftUI/`.

iPodKit, MediaKit, DeviceKit et le CLI existent : voir [[Package Swift]]. Écarts avec le plan ci-dessus : une seule cible MediaKit au lieu de MediaKitApple et MediaKitPortable, un SHA-1 maison au lieu de swift-crypto, une cible C `CWinDevices` pour Windows. Les modèles de bibliothèque (`LibraryTrack`, `DeviceSyncRecord`…) sont dans iPodKit, parce que `SyncEngine` en dépend ; ils pourront passer dans AppModel en phase 3. Voir [[ADR-006 Noyau portable sans dépendance Apple]].
