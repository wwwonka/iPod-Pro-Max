# iPod Pro Max

Une application Swift multiplateforme pour gérer et synchroniser des iPods classiques, avec SwiftCrossUI : AppKit sur macOS, GTK 4 sur Linux et WinUI sur Windows.

Le projet est issu du [projet de Stephen Robles](https://github.com/stephenrobles/iPod-Pro-Max), conservé comme origine et référence. L’interface SwiftCrossUI, auparavant expérimentale, est désormais l’application principale. Les fonctionnalités de l’ancienne application sont reprises progressivement.

## Organisation

| Dossier | Rôle |
|---|---|
| `iPod Pro Max/App/` | Entrée de l’application et composition des écrans |
| `iPod Pro Max/UI/` | Interface et composants natifs par plateforme |
| `iPod Pro Max/Library/` | Lecture et indexation de la bibliothèque |
| `iPod Pro Max/Platforms/` | Intégration système et suivi des appareils |
| `iPod Pro Max/Resources/` | Icônes et ressources |
| `Sources/` | Modules partagés : iPodKit, MediaKit, DeviceKit, CWinDevices et CLI |
| `Tests/` | Tests des modules partagés |
| `Tools/Build/` | Compilation, lancement et correctifs SwiftCrossUI |
| `Tools/DbTest/`, `Tools/GpodCheck/`, `Tools/FFmpeg/` | Diagnostics et outils média |
| `Docs/` | Documentation et vault Obsidian |
| `Refs/` | Liens, ancienne app SwiftUI, site d’origine et diagnostics conservés |

Un seul `Package.swift` à la racine décrit l’application, les bibliothèques et la CLI. Les dossiers utilisent une majuscule initiale ; les noms techniques existants comme `iPodKit`, `ipodpromax` et les dossiers cachés des outils gardent leur orthographe. Aucun dossier vide n’est ajouté pour les fonctionnalités futures.

## Compiler et lancer

Depuis le Finder, double-cliquer sur `Build.command` : il construit les trois OS, puis fait de `Build/` la **racine d’un iPod** (FAT32) avec les applications, la CLI, un `iPod_Control/` simulé et le lanceur `LAUNCHER.bat`. Le build ne touche jamais un vrai iPod. Linux se compile dans Docker (OrbStack) sur le Mac ; Windows utilise encore la VM Parallels.

Depuis la racine du dépôt :

```sh
Tools/Build/build.sh              # mac + linux + windows, puis Build/
Tools/Build/build.sh mac --run    # seulement macOS, puis lance l’app par Build/LAUNCHER.bat
Tools/Build/build.sh --clean      # repart de zéro, iPod_Control et Persistent Data compris
sh Build/LAUNCHER.bat cli list    # la CLI de cet OS, depuis l’iPod simulé
Tools/Build/run-mac.sh            # lancement de développement
Tools/Build/run-mac.sh gtk        # aperçu GTK sur Mac
```

`iPod_Control/` et `iPod Pro Max/Persistent Data/` (réglages partagés par les 3 OS) sont conservés d’un build à l’autre. Ce qu’on veut simplement retrouver sur l’iPod va dans `Distribution/iPod Root/`. Disposition : [Sur l’iPod](Docs/Données/Sur%20l'iPod.md).

Les scripts résolvent les dépendances et appliquent les correctifs SwiftCrossUI avant de compiler. Les exécutables s’appellent `iPodProMaxApp` (interface) et `ipodpromax` (CLI), pour éviter une collision sur les disques insensibles à la casse.

```sh
swift build --product ipodpromax
swift test
.build/debug/ipodpromax list
```

Détails : [application SwiftCrossUI](Docs/Architecture/Application%20SwiftCrossUI.md). Les étapes intermédiaires (ffmpeg, icônes, logs, build de chaque OS) vont dans `.build-work/`, l’iPod dans `Build/`, les ressources privées restent dans `iPod Pro Max/Resources/Local/`. Ces dossiers sont ignorés par Git.

## État fonctionnel

L’interface actuelle comprend la bibliothèque musicale, la navigation, la recherche et la détection des iPods. La page appareil lit les informations et permet l’éjection. La sélection multiple de chansons ou d’artistes (Cmd/Ctrl-clic et Shift-clic) et leur dépôt sur un iPod lancent un transfert en ajout uniquement, sans supprimer les autres pistes, playlists ou pochettes. Le bouton + configure le dossier musical de l’hôte et la flèche circulaire actualise la bibliothèque. Sync complet (avec crochets par piste), Import et Forget restent à connecter. Les données de l’app restent sur l’iPod : `known_hosts.json`, caches de bibliothèque par hôte, pochettes, conversions et préférences. Seuls les médias accessibles apparaissent; les dossiers sources restent mémorisés même indisponibles. Le lanceur exécute directement l’app depuis l’iPod. Le noyau portable fournit aussi une CLI.

L’ancienne application macOS et ses fonctionnalités sont décrites dans [Refs/SwiftUI/README.md](Refs/SwiftUI/README.md). Son projet Xcode reste disponible dans `Refs/SwiftUI/iPod Pro Max.xcodeproj`. `Tools/release.sh` reste réservé à cette ancienne application ; la compilation de l’application principale passe par `Tools/Build/build.sh`.

## Documentation et suite

Ouvrir `Docs/` dans Obsidian. Les anciennes phases et décisions documentent l’évolution du projet ; elles ne constituent pas une nouvelle liste de tâches. La vision finale et le prochain GitHub Project seront définis avec le propriétaire après ce rangement.

## Licence et origine

MIT — voir [LICENSE](LICENSE). Le code issu du projet de Stephen Robles conserve ses mentions d’origine. iPod est une marque d’Apple ; ce projet n’est ni affilié à Apple ni approuvé par Apple.
