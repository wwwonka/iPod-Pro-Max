# Prototype SwiftCrossUI (P1, phase 0)

Prototype jetable de la vue Musique, écrit une seule fois en Swift et lancé sur macOS, Windows 11 et Fedora. Voir `docs/Feuille de route/Prototypes phase 0.md`.

**Objectif de rendu : natif sur chaque OS.** Le prototype utilise le `DefaultBackend` de SwiftCrossUI :

| OS | Backend | Rendu |
|---|---|---|
| macOS | AppKit | contrôles Mac |
| Windows 11 | WinUI 3 | contrôles Fluent |
| Fedora | GTK 4 | Adwaita (GNOME) |

> Ça s'écarte de l'ADR-003 (GTK + thème Mac sur Windows et Linux). À trancher après les tests, puis à reporter dans les ADR.

## Ce que fait le prototype
- Il charge le vrai `library.json`, hors du thread principal, puis l'indexe par artiste et par album.
- Il affiche une sidebar (Artistes, Albums, Morceaux), une liste, puis une `Table` des pistes. « Morceaux » montre les 5 000+ lignes : c'est le test de défilement.
- Il écrit les temps dans la console : `decode … ms, index … ms, ready … ms`.

Le `library.json` est cherché dans cet ordre :
1. `--library <chemin>` ou la variable `IPPM_LIBRARY`.
2. Celui de l'app sur le Mac : `~/Library/Application Support/iPod Pro Max/library.json`.
3. Le dossier personnel du Mac partagé par Parallels : `\\Mac\Home\…` sous Windows, `/media/psf/Home/…` sous Linux.
4. `library.json` dans le dossier courant.
5. Sinon, 5 000 pistes synthétiques.

Dans les VM, le point 3 suffit si le partage du dossier personnel est activé dans Parallels (Configuration › Options › Partage).

## Construire les trois apps depuis le Mac : `build.sh`
Un seul script, lancé sur le Mac. Il compile l'app Mac en local, puis pilote les VM Parallels avec `prlctl exec`. Il démarre une VM si elle est éteinte, et compile Fedora et Windows en parallèle.

```sh
./build.sh --setup          # première fois : installe aussi Swift, GTK et WinUI dans les VM
./build.sh                  # ensuite : mac + linux + windows
./build.sh mac linux        # seulement certaines cibles
./build.sh --run mac        # ouvre l'app Mac une fois construite
```

Résultats :

| Cible | Sortie |
|---|---|
| Mac | `dist/mac/iPod Pro Max Proto.app` (arm64, signée ad hoc) |
| Fedora | `dist/linux/iPodProMaxProto` (runtime Swift statique, seul GTK 4 vient du système) |
| Windows | `dist/windows/` (exe + DLL Swift et WinUI) |

Les journaux des VM vont dans `dist/linux.log` et `dist/windows.log`.

Comment ça marche :
- Les VM lisent les sources et écrivent `dist/` par le dossier personnel du Mac partagé par Parallels. Le script l'active dans Fedora s'il est désactivé.
- Chaque VM compile dans une copie locale (`~/dev/swiftcrossui`, `C:\dev\swiftcrossui`), parce que compiler sur le partage est lent. Les builds suivants sont donc incrémentaux.
- Dans les VM, il faut une **session utilisateur ouverte**, parce que `prlctl exec --current-user` s'en sert.
- Les noms des VM sont « Fedora Linux » et « Windows 11 ». Tu peux les changer avec `LINUX_VM=… WINDOWS_VM=… ./build.sh`.

Ce que fait `--setup` :
- **Fedora** (en root) : installe `gtk4-devel`, `clang` et les dépendances du toolchain, puis Swift avec swiftly dans ton compte.
- **Windows** : installe, avec WinGet, Visual Studio 2022 (outils C++ ARM64 + SDK), Swift, le Windows SDK 17763 et le Windows App Runtime 1.5. Windows demande des validations administrateur dans la VM, et l'installation de Visual Studio prend un moment.

Mesuré sur le Mac le 2026-10-23, en debug, avec 5 328 pistes : AppKit prêt en 62 ms (155 Mo) ; GTK prêt en 263 ms (135 Mo). `./run-mac.sh gtk` montre le rendu GTK sur le Mac, sans VM (`brew install pkg-config gtk4`).

Les scripts appelés dans les VM (`scripts/build-linux.sh`, `scripts/build-windows.ps1`) peuvent aussi se lancer à la main dans la VM en cas de souci.

## Quoi noter sur chaque OS
- Le temps `ready` affiché dans la console.
- La mémoire, dans le Moniteur d'activité, le Gestionnaire des tâches ou `top`.
- La fluidité du défilement de « Morceaux » (5 000 lignes).
- Le redimensionnement de la fenêtre et des colonnes.
- L'impression générale : est-ce que ça a l'air natif ?

Les manques connus de SwiftCrossUI 0.10.0 ne sont pas encore couverts : multisélection, tri par colonne et glisser-déposer. Voir `docs/Interface/Manques SwiftCrossUI.md`.
