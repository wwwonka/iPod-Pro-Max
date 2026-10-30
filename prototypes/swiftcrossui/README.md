# Prototype SwiftCrossUI (P1, phase 0)

Prototype jetable de la vue Musique, écrit une fois en Swift et lancé sur macOS, Fedora et Windows 11. Il sert à valider SwiftCrossUI avant de s'engager. Résultats et leçons : `docs/Feuille de route/Prototypes phase 0.md`. Méthode : `docs/Interface/Composants natifs par plateforme.md`.

## Lancer
Depuis le Finder, double-cliquer à la racine du repo :

| Lanceur | Effet |
|---|---|
| `build-mac.command` | construit l'app Mac et l'ouvre |
| `build-linux.command` | construit dans la VM « Fedora Linux » et ouvre l'app dans sa session |
| `build-windows.command` | construit dans la VM « Windows 11 » et ouvre l'app |

Ils appellent `build.sh <os> --run`. La première fois, `build.sh` installe ce qui manque dans la VM :
- **Fedora** : `swift-lang` (le Swift de Fedora : swiftly ne gère pas Fedora 44), `gtk4-devel`, `clang`, `rsync`.
- **Windows** : Visual Studio 2022 (outils C++ ARM64), Swift, Git, le Windows App Runtime, et le mode développeur (liens symboliques). Windows demande des validations administrateur dans la VM.

Autres usages :

```sh
./build.sh                  # mac + linux + windows
./build.sh mac linux        # seulement certaines cibles
./build.sh --setup windows  # forcer la réinstallation des outils
./run-mac.sh gtk            # rendu GTK sur le Mac, sans VM (brew install pkg-config gtk4)
```

Comment ça marche :
- Les VM lisent les sources et écrivent `dist/` par le dossier personnel du Mac partagé par Parallels, et compilent dans une copie locale (`~/dev/swiftcrossui`, `C:\dev\swiftcrossui`).
- Les iPods viennent de DeviceKit, le noyau portable du repo (`../../Package.swift`). Les VM en font aussi une copie locale (`~/dev/ipodpromax-core`, `C:\dev\ipodpromax-core`), que le manifeste trouve par la variable `IPPM_CORE` ; sur le Mac, il prend `../..`.
- Il faut une **session ouverte** dans chaque VM (`prlctl exec --current-user`).
- Sous Windows, le build tourne détaché dans la VM (`prlctl` coupait les longues sessions) et écrit `dist/windows-vm.log` et `dist/windows-vm.exit`.
- Sous Linux, on force `SCUI_DEFAULT_BACKEND=GtkBackend` ; sous Windows, `WinUIBackend` (sinon SwiftPM compile aussi l'autre backend et échoue).
- `scripts/patch-dependencies.sh` corrige SwiftCrossUI avant chaque build (les 3 OS), en attendant que ce soit fait en amont :
  - GTK : réutilisation du contexte Pango ;
  - `scripts/patches/representables.patch` : les vues natives recevaient pour toujours les valeurs de leur création (tableau vide, recherche sans effet) ;
  - `scripts/patches/winui-backend.patch` : split view que l'app peut dimensionner et faire glisser, cache des mesures de texte, fond transparent sous l'acrylique, vraie taille de la fenêtre ;
  - `scripts/patches/gtk-backend.patch` : CSS rechargé à chaque mise à jour (la moitié du temps de chaque mise en page), cache des mesures de texte.

  Sous Windows, il tourne avec le bash fourni par Git.
- Dans la VM Linux, l'app est lancée avec `GSK_RENDERER=vulkan` : le rendu GL de GTK y cale les premiers glissements (GPU virtio).

## Données
`library.json` est cherché dans cet ordre : `--library <chemin>` ou `IPPM_LIBRARY` ; celui de l'app Mac ; le dossier personnel du Mac vu depuis la VM ; `library.json` dans le dossier courant. Si rien n'est trouvé **ou si la bibliothèque est vide**, le prototype génère 5 000 pistes et deux playlists.

## Icônes (à lire)
- **Mac** : vrais SF Symbols.
- **Linux et Windows** : glyphes de la police `SF-SYMBOLS4.TTF` (github.com/DrunkSonic/SF-Symbols-for-Windows), associés aux noms des symboles par comparaison de forme (`symbolCodepoints` dans `Symbols.swift`). C'est l'œuvre d'Apple, sans licence pour cet usage : elle se met **à la main** dans `local/` (ignoré par Git), le script de build l'installe seulement dans la VM (Linux : `~/.local/share/fonts` ; Windows : polices de l'utilisateur, sans droits administrateur), et elle n'est **jamais commitée ni distribuée**. Sans elle, les icônes sont des cases vides. `film` y est horizontal, comme dans SF Symbols 4.

## Variables d'environnement
| Variable | Effet |
|---|---|
| `IPPM_BENCH=<tours>` | change de section comme des clics, journalise le temps de chaque mise à jour, ouvre et ferme la sidebar (nombre d'images ; sous Windows, aussi le temps de mise en page par image), puis quitte |
| `IPPM_SLIDE_SECONDS=<s>` | ralentit le glissement de la sidebar, pour en regarder les images |
| `IPPM_SNAPSHOT=<fichier.png>` | (Mac) enregistre la fenêtre telle que l'app la dessine, puis quitte ; `IPPM_SNAPSHOT_COLLAPSED=1` ferme d'abord la sidebar |
| `IPPM_LOG=<fichier>` | journal dans un fichier ; sous Windows, `%TEMP%\ippm.log` par défaut (une app lancée depuis l'Explorateur n'a pas de console) |

## Icône de l'app
`Assets/AppIcon.appiconset` est la seule source. `scripts/make-icons.sh` (lancé par `build.sh`) en tire `dist/icons/AppIcon.icns` pour le bundle Mac et `dist/icons/AppIcon.ico` pour Windows (ressource de l'exécutable, compilée avec `rc.exe`, et icône de la fenêtre). Sous Linux, `build-linux.sh` installe les PNG dans le thème d'icônes de l'utilisateur, avec un fichier `.desktop` au nom de l'identifiant de l'app (`com.ipodpromax.proto`).

## Fichiers
| Fichier | Rôle |
|---|---|
| `App.swift` | fenêtre, sections, en-tête, vue Musique, mesure |
| `Library.swift` | lecture et indexation de `library.json` hors du thread principal |
| `ArtistList.swift` | liste « By Artist » native : `NSTableView`, `GtkListView`, `ListView` WinUI |
| `TrackTable.swift` | tableau virtualisé : `NSTableView`, `GtkColumnView`, `ListView` WinUI |
| `Sidebar.swift`, `SidebarMac.swift`, `SidebarGtk.swift`, `SidebarWinUI.swift` | éléments de la sidebar ; sidebar native Mac, GTK et WinUI |
| `Sidebar.swift` | sections de la sidebar et mesures du Mac (`SidebarMetrics`), partagées par les 3 OS |
| `Symbols.swift` | SF Symbols par plateforme ; `scripts/match-glyph.swift` retrouve un glyphe de la police par sa forme |
| `WindowChrome.swift` | modèle commun de la fenêtre sans barre et du glissement de la sidebar |
| `WindowChromeMac.swift`, `WindowChromeGtk.swift`, `WindowChromeWinUI.swift` | fenêtre, déplacement, boutons et glissement par plateforme ; mode sombre et coins arrondis GTK |
| `Devices.swift` | iPods montés, par DeviceKit (`DeviceScanner`), mis à jour à chaque montage ou démontage (`VolumeWatcher`, sans polling) |
