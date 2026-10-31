# Application SwiftCrossUI

Application principale du projet depuis le 2026-10-30, écrite en Swift et lancée sur macOS, Fedora et Windows 11. Son code est dans `iPod Pro Max/` ; le package unique est à la racine. Résultats et leçons : `Docs/Feuille de route/Prototypes phase 0.md`. Méthode : `Docs/Interface/Composants natifs par plateforme.md`.

## Lancer
Depuis le Finder, double-cliquer sur `Build.command` à la racine du repo. Il appelle `Tools/Build/build.sh`, qui construit les trois OS dans `.build-work/<os>/`, puis `Tools/Build/assemble-ipod.sh` fait de `Build/` la racine d'un iPod (disposition dans [[Sur l'iPod]]). On lance ensuite l'app par `Build/LAUNCHER.command` (Mac), `Build\LAUNCHER.bat` (Windows) ou `sh Build/LAUNCHER.bat` (Linux).

| OS | Où ça compile | Sortie |
|---|---|---|
| macOS | sur le Mac, arm64 puis x86_64, réunis par `lipo` (le build multi-architecture de SwiftPM ne sait pas compiler les macros de SwiftCrossUI) | `.build-work/mac/app`, `.build-work/mac/cli` |
| Linux | Docker sur le Mac (OrbStack), image `swift:6.1.2-jammy` + GTK 4, x86_64 et aarch64 : `Tools/Build/build-linux-docker.sh`. `IPPM_LINUX_BUILD=vm` reprend l'ancienne VM Fedora. | `.build-work/linux/<arch>`, `.build-work/linux-cli/<arch>` |
| Windows | VM Parallels « Windows 11 » (aucune compilation fiable de WinUI depuis macOS) | `.build-work/windows/<arch>`, `.build-work/windows-cli/<arch>` |

La première fois, `build.sh` installe ce qui manque dans la VM Windows : Visual Studio 2022 (outils C++ ARM64), Swift, Git, le Windows App Runtime, et le mode développeur (liens symboliques). Windows demande des validations administrateur dans la VM. Docker installe lui-même son image et le SDK Linux statique (une fois, en cache dans `.build-work/linux-docker/`).

Autres usages :

```sh
Tools/Build/build.sh                  # mac + linux + windows, puis Build/
Tools/Build/build.sh mac linux        # seulement certaines cibles (Build/ garde la dernière version des autres)
Tools/Build/build.sh --clean          # Build/ repart de zéro, iPod_Control et Persistent Data compris
Tools/Build/build.sh --setup windows  # forcer la réinstallation des outils
Tools/Build/run-mac.sh gtk            # rendu GTK sur le Mac, sans VM (brew install pkg-config gtk4)
```

Comment ça marche :
- La VM Windows lit les sources et écrit `.build-work/` par le dossier personnel du Mac partagé par Parallels, et compile dans une copie locale (`C:\dev\swiftcrossui`).
- Les iPods viennent de DeviceKit dans `Sources/`. Les VM copient le package racine et compilent l’application avec les modules partagés, sans second package ni variable `IPPM_CORE`.
- Il faut une **session ouverte** dans chaque VM (`prlctl exec --current-user`).
- Sous Windows, le build tourne détaché dans la VM (`prlctl` coupait les longues sessions) et écrit `.build-work/windows-vm.log` et `.build-work/windows-vm.exit`.
- Sous Linux, on force `SCUI_DEFAULT_BACKEND=GtkBackend` ; sous Windows, `WinUIBackend` (sinon SwiftPM compile aussi l'autre backend et échoue).
- `Tools/Build/patch-dependencies.sh` corrige SwiftCrossUI avant chaque build (les 3 OS), en attendant que ce soit fait en amont :
  - GTK : réutilisation du contexte Pango ;
  - `Tools/Build/Patches/representables.patch` : les vues natives recevaient pour toujours les valeurs de leur création (tableau vide, recherche sans effet) ;
  - `Tools/Build/Patches/winui-backend.patch` : split view que l'app peut dimensionner et faire glisser, cache des mesures de texte, fond transparent sous l'acrylique, vraie taille de la fenêtre ;
  - `Tools/Build/Patches/gtk-backend.patch` : CSS rechargé à chaque mise à jour (la moitié du temps de chaque mise en page), cache des mesures de texte.

  Sous Windows, il tourne avec le bash fourni par Git.
- Dans la VM Linux, l'app est lancée avec `GSK_RENDERER=vulkan` : le rendu GL de GTK y cale les premiers glissements (GPU virtio).

## Données
`library.json` est cherché dans cet ordre : `--library <chemin>` ou `IPPM_LIBRARY` ; celui de l'app Mac ; le dossier personnel du Mac vu depuis la VM ; `library.json` dans le dossier courant. Si rien n'est trouvé **ou si la bibliothèque est vide**, l’application génère 5 000 pistes et deux playlists.

## Icônes (à lire)
- **Mac** : vrais SF Symbols.
- **Linux et Windows** : glyphes de la police `SF-SYMBOLS4.TTF` (github.com/DrunkSonic/SF-Symbols-for-Windows), associés aux noms des symboles par comparaison de forme (`symbolCodepoints` dans `Symbols.swift`). C'est l'œuvre d'Apple, sans licence pour cet usage : elle se met **à la main** dans `iPod Pro Max/Resources/Local/` (ignoré par Git), le script de build l'installe seulement dans la VM (Linux : `~/.local/share/fonts` ; Windows : polices de l'utilisateur, sans droits administrateur), et elle n'est **jamais commitée ni distribuée**. Sans elle, les icônes sont des cases vides. `film` y est horizontal, comme dans SF Symbols 4.

## Variables d'environnement
| Variable | Effet |
|---|---|
| `IPPM_BENCH=<tours>` | change de section comme des clics, journalise le temps de chaque mise à jour, ouvre et ferme la sidebar (nombre d'images ; sous Windows, aussi le temps de mise en page par image), puis quitte |
| `IPPM_SLIDE_SECONDS=<s>` | ralentit le glissement de la sidebar, pour en regarder les images |
| `IPPM_SNAPSHOT=<fichier.png>` | (Mac) enregistre la fenêtre telle que l'app la dessine, puis quitte ; `IPPM_SNAPSHOT_COLLAPSED=1` ferme d'abord la sidebar |
| `IPPM_LOG=<fichier>` | journal dans un fichier ; sous Windows, `%TEMP%\ippm.log` par défaut (une app lancée depuis l'Explorateur n'a pas de console) |

## Icône de l'app
`iPod Pro Max/Resources/AppIcon.appiconset` est la seule source. `Tools/Build/make-icons.sh` (lancé par `build.sh`) en tire `.build-work/icons/AppIcon.icns` pour le bundle Mac et `.build-work/icons/AppIcon.ico` pour Windows (ressource de l'exécutable, compilée avec `rc.exe`, et icône de la fenêtre). Sous Linux, `build-linux.sh` installe les PNG dans le thème d'icônes de l'utilisateur, avec un fichier `.desktop` au nom de l'identifiant de l'app (`com.ipodpromax.proto`).

## Fichiers
| Fichier | Rôle |
|---|---|
| `App.swift` | fenêtre, sections, en-tête, vue Musique, mesure |
| `Library.swift` | lecture et indexation de `library.json` hors du thread principal |
| `ArtistList.swift` | liste « By Artist » native : `NSTableView`, `GtkListView`, `ListView` WinUI |
| `TrackTable.swift` | tableau virtualisé : `NSTableView`, `GtkColumnView`, `ListView` WinUI |
| `Sidebar.swift`, `SidebarMac.swift`, `SidebarGtk.swift`, `SidebarWinUI.swift` | éléments de la sidebar ; sidebar native Mac, GTK et WinUI ; bouton d'éjection des iPods comme dans le Finder (couleurs système sur Mac, `ejectButtonRGB` ailleurs) |
| `Sidebar.swift` | sections de la sidebar et mesures du Mac (`SidebarMetrics`), partagées par les 3 OS |
| `Symbols.swift` | SF Symbols par plateforme ; `Tools/Build/match-glyph.swift` retrouve un glyphe de la police par sa forme |
| `WindowChrome.swift` | modèle commun de la fenêtre sans barre et du glissement de la sidebar |
| `WindowChromeMac.swift`, `WindowChromeGtk.swift`, `WindowChromeWinUI.swift` | fenêtre, déplacement, boutons et glissement par plateforme ; mode sombre et coins arrondis GTK |
| `Devices.swift` | iPods montés, par DeviceKit (`DeviceScanner`), mis à jour à chaque montage ou démontage (`VolumeWatcher`, sans polling), plus l'iPod simulé d'où l'app est lancée |
| `PortableRoot.swift` | racine de l'iPod d'où l'app est lancée : `--portable-root` (passé par LAUNCHER), `IPPM_PORTABLE_ROOT`, ou son propre emplacement sous `iPod Pro Max/Applications/` ; `Build/` y apparaît comme iPod simulé. `DeviceOptions` : le `device.json` de chaque iPod |
| `DeviceView.swift` | page d'un iPod, copiée du `DeviceView` de l'app Mac : nom (renommable), modèle, contenu et espace lus sur l'iPod par iPodKit ; options de synchro enregistrées sur cet iPod (`Persistent Data/device.json`) ; Sync, Import et Forget affichés mais pas branchés (moteur partagé pas encore connecté à l’interface) ; Eject et « Show in Finder/Files/Explorer » fonctionnent |

## Organisation depuis la promotion

`App.swift` est dans `App/`, `Library.swift` dans `Library/`, `Devices.swift` dans `Platforms/` et les composants visuels dans `UI/`, sous `iPod Pro Max/`. Les variantes Mac, GTK et WinUI restent près de leur composant. L’identifiant technique `com.ipodpromax.proto` est conservé pendant le rangement pour préserver les préférences et l’intégration existantes ; le nom visible est iPod Pro Max.
