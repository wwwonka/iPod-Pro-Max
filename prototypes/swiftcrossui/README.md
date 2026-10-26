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
- Il faut une **session ouverte** dans chaque VM (`prlctl exec --current-user`).
- Sous Windows, le build tourne détaché dans la VM (`prlctl` coupait les longues sessions) et écrit `dist/windows-vm.log` et `dist/windows-vm.exit`.
- Sous Linux, on force `SCUI_DEFAULT_BACKEND=GtkBackend` ; sous Windows, `WinUIBackend` (sinon SwiftPM compile aussi l'autre backend et échoue).
- `scripts/patch-dependencies.sh` corrige SwiftCrossUI avant chaque build GTK (réutilisation du contexte Pango), en attendant que ce soit fait en amont.

## Données
`library.json` est cherché dans cet ordre : `--library <chemin>` ou `IPPM_LIBRARY` ; celui de l'app Mac ; le dossier personnel du Mac vu depuis la VM ; `library.json` dans le dossier courant. Si rien n'est trouvé **ou si la bibliothèque est vide**, le prototype génère 5 000 pistes et deux playlists.

## Icônes (à lire)
- **Mac** : vrais SF Symbols.
- **Linux et Windows** : glyphes de la police `SF-SYMBOLS4.TTF` (github.com/DrunkSonic/SF-Symbols-for-Windows), associés aux noms des symboles par comparaison de forme (`symbolCodepoints` dans `Symbols.swift`). C'est l'œuvre d'Apple, sans licence pour cet usage : elle se met **à la main** dans `local/` (ignoré par Git), le script de build la copie seulement dans la VM, et elle n'est **jamais commitée ni distribuée**. Sans elle, les icônes sont des cases vides. Il manque `film` (Videos) dans la police ; `sidebar.left` utilise le glyphe le plus proche.

## Variables d'environnement
| Variable | Effet |
|---|---|
| `IPPM_BENCH=<tours>` | change de section comme des clics, journalise le temps de chaque mise à jour, ouvre et ferme la sidebar (nombre d'images), puis quitte |
| `IPPM_SNAPSHOT=<fichier.png>` | (Mac) enregistre la fenêtre telle que l'app la dessine, puis quitte ; `IPPM_SNAPSHOT_COLLAPSED=1` ferme d'abord la sidebar |
| `IPPM_LOG=<fichier>` | journal dans un fichier ; sous Windows, `%TEMP%\ippm.log` par défaut (une app lancée depuis l'Explorateur n'a pas de console) |

## Fichiers
| Fichier | Rôle |
|---|---|
| `App.swift` | fenêtre, sections, en-tête, vue Musique, mesure |
| `Library.swift` | lecture et indexation de `library.json` hors du thread principal |
| `TrackTable.swift` | tableau virtualisé : `NSTableView`, `GtkColumnView`, `ListView` WinUI |
| `SidebarMac.swift`, `SidebarGtk.swift`, `Sidebar.swift` | sidebar native Mac, native GTK, dessinée (WinUI) |
| `Symbols.swift` | SF Symbols par plateforme |
| `WindowChrome.swift` | fenêtre sans barre, bouton et animation de la sidebar, mode sombre GTK, coins arrondis GTK |
| `Devices.swift` | iPods montés au lancement |
