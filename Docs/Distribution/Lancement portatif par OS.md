# Lancement portatif par OS

## Exécution depuis l'iPod

Depuis [[ADR-006 Application entièrement portable]], le lanceur exécute directement l'application depuis l'iPod, sans copie persistante sur l'ordinateur. `Distribution/Launcher/LAUNCHER.bat` reste un script polyglotte sh/cmd, également distribué comme `LAUNCHER.command` pour macOS.

Le lanceur transmet `IPPM_PORTABLE_ROOT` (et `--portable-root` pour les interfaces POSIX). L'application charge les préférences communes, l'hôte connu et son cache depuis `iPod Pro Max/Persistent Data/`. L'option `cli` lance directement l'outil correspondant à l'OS.

## macOS

Application universelle arm64/x86_64, signée ad hoc. Le lancement passe par `open` avec la racine portable explicite. Le lanceur ne retire pas la quarantaine et ne contourne pas Gatekeeper. Les autorisations système et traces produites par macOS restent gérées par l'OS.

## Windows

Exécutable WinUI et dépendances à côté, dans `Applications/Windows/<arch>/`. Le Windows App Runtime doit être disponible. L'exécution depuis le volume peut empêcher son éjection : fermer l'application avant d'éjecter dans Windows. La pile du thread principal reste à 8 Mo (`/STACK:8388608`).

## Linux

Binaire avec runtime Swift statique, glibc et GTK4 dynamiques. Le montage doit autoriser l'exécution du binaire (`noexec` et certains montages FAT32 `showexec` l'empêchent). Le lanceur affiche une erreur si le binaire ne peut pas être exécuté; il ne crée aucune copie locale de secours.

## FAT32

Le mode portatif multiplateforme repose sur un iPod FAT32. Voir [[ADR-005 FAT32 en mode portatif]]. Les fichiers temporaires de sauvegarde et de conversion de l'application sont placés sur l'iPod; la bibliothèque musicale originale reste sur l'hôte.
