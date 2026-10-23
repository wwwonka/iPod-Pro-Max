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

## macOS (testé)
```sh
./run-mac.sh          # AppKit, rendu natif
./run-mac.sh gtk      # GTK 4 sur le Mac : aperçu rapide du rendu Linux (brew install pkg-config gtk4)
```
Mesuré le 2026-10-23 en debug, avec 5 328 pistes : AppKit prêt en 62 ms (155 Mo) ; GTK prêt en 263 ms (135 Mo).

## Fedora (VM Parallels, aarch64)
1. Installe les Parallels Tools, pour avoir `/media/psf/Home`.
2. Installe Swift avec swiftly (voir swift.org/install/linux) :
   ```sh
   curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
   tar zxf swiftly-$(uname -m).tar.gz && ./swiftly init
   ```
3. Installe GTK : `sudo dnf install gtk4-devel clang`
4. Copie le dossier en local, parce que compiler sur le partage est lent :
   ```sh
   rsync -a --exclude '.build*' "/media/psf/Home/<chemin>/prototypes/swiftcrossui/" ~/swiftcrossui/
   cd ~/swiftcrossui && ./run-linux.sh
   ```

## Windows 11 (VM Parallels, ARM64)
1. Installe Swift avec WinGet, en suivant **swift.org/install/windows**. Il faut d'abord Visual Studio 2022 avec les composants indiqués, en choisissant les outils **ARM64**. Ouvre ensuite un nouveau terminal et vérifie avec `swift --version`.
2. Installe les dépendances de WinUI :
   ```powershell
   winget install --id Microsoft.WindowsSDK.10.0.17763
   ```
   Installe aussi le Windows App Runtime 1.5.240205001-preview1 **arm64** : https://aka.ms/windowsappsdk/1.5/1.5.240205001-preview1/windowsappruntimeinstall-arm64.exe
3. Copie le dossier dans un chemin local **sans espaces**, puis lance :
   ```powershell
   robocopy "\\Mac\Home\<chemin>\prototypes\swiftcrossui" C:\dev\swiftcrossui /E /XD .build .build-gtk
   cd C:\dev\swiftcrossui
   .\run-windows.ps1
   ```

## Quoi noter sur chaque OS
- Le temps `ready` affiché dans la console.
- La mémoire, dans le Moniteur d'activité, le Gestionnaire des tâches ou `top`.
- La fluidité du défilement de « Morceaux » (5 000 lignes).
- Le redimensionnement de la fenêtre et des colonnes.
- L'impression générale : est-ce que ça a l'air natif ?

Les manques connus de SwiftCrossUI 0.10.0 ne sont pas encore couverts : multisélection, tri par colonne et glisser-déposer. Voir `docs/Interface/Manques SwiftCrossUI.md`.
