# CLI ipodpromax

L'outil en ligne de commande de la phase 4 : **synchroniser un iPod depuis n'importe quel ordi** avec le même moteur que l'app. Source : `Sources/ipodpromax/main.swift`. Il sert aussi de banc d'essai pour iPodKit, MediaKit et DeviceKit sur chaque OS.

## Commandes

```
ipodpromax list                         iPods montés
ipodpromax info   [--ipod <chemin>]     modèle, capacité, contenu de la base
ipodpromax sync   <dossier> [--ipod <chemin>] [--remove-unknown] [--no-artwork] [--eject] [--verbose]
ipodpromax eject  [--ipod <chemin>]     démonte l'iPod pour qu'on puisse le débrancher
ipodpromax watch                        affiche les iPods branchés et retirés (Ctrl-C pour arrêter)
ipodpromax tags   <fichier>…            les tags tels qu'iPod Pro Max les lit
                  [--portable]          force le lecteur en Swift pur (sur Mac)
                  [--compare]           Mac : compare AVFoundation et le lecteur portable
ipodpromax tags --bench <dossier>       chronomètre la lecture des tags (et compare, sur Mac)
ipodpromax init-sim <dossier> [--model <numéro>]
                                        fait d'un dossier un iPod simulé, pour essayer
```

`--ipod` prend le point de montage (`/Volumes/IPOD`, `/run/media/moi/IPOD`, `E:\`) ou un dossier créé par `init-sim`. Il est facultatif quand un seul iPod est monté.

## Ce que fait `sync <dossier>`
1. **Lit le dossier** en parallèle, un fichier par cœur (`FolderImporter`) : tags, durée, pochette (une seule fois par album, réencodée en JPEG de 600 px au plus). Les fichiers cachés sont ignorés.
2. **Identifie chaque piste par son chemin relatif** au dossier (UUID dérivé d'un SHA-1). Le même dossier garde les mêmes identifiants d'une fois et d'un ordi à l'autre.
3. **Relit le registre** de ce qu'il a mis sur cet iPod : `iPod Pro Max/Data/cli-sync.json`, sur l'iPod lui-même (voir [[Sur l'iPod]]). Écriture sûre avec génération précédente en `.bak`. C'est un précurseur du [[Manifeste et propriété des pistes]].
4. **Lance `SyncEngine`**, comme l'app : ajout de ce qui manque, retrait de ce qui a quitté le dossier, conversion de ce que l'iPod ne lit pas (FLAC, OGG… → AAC ; vidéo → H.264 Baseline), réécriture ID3 v2.3 pour les paroles, pochettes, livres audio, signature hash58 si le modèle l'exige.
5. Les pistes présentes sur l'iPod mais **pas venues de ce dossier sont gardées**, sauf avec `--remove-unknown`.

Les caches (pochettes, conversions) vont dans le dossier de cache de l'OS : `~/Library/Caches/iPodProMax/cli`, `~/.cache/iPodProMax/cli`, `%LOCALAPPDATA%\iPodProMax\cli` (voir [[ADR-004 Caches sur l'hôte]]).

Pas de podcasts ni de photos dans le CLI : ils viennent de la bibliothèque et de Photos de l'app.

## ffmpeg
Nécessaire seulement pour convertir (FLAC, OGG, vidéo hors Mac, livres audio en plusieurs fichiers). Sans lui, ces fichiers sont signalés en échec avec la marche à suivre, et le reste se synchronise. Il est cherché dans cet ordre :
1. la variable `IPODPROMAX_FFMPEG` ;
2. à côté de l'exécutable ;
3. `Tools/<OS>/ffmpeg` à côté de l'exécutable ou un ou deux niveaux plus haut, c'est-à-dire la disposition prévue sur l'iPod ([[Sur l'iPod]]) ;
4. le `PATH`, puis les emplacements Homebrew et système.

ffmpeg est toujours lancé avec `-nostdin` : sans console, il guette le clavier et tourne à 100 % du CPU sous Windows sans jamais finir.

Pour la vidéo, le premier encodeur H.264 disponible est choisi : libx264, puis les encodeurs matériels (nvenc, qsv, amf, mf, vaapi), puis libopenh264. Le ffmpeg-free de Fedora n'a que libopenh264.

## Essais faits (2026-10-30)
Même dossier de 47 pistes (MP3, M4A, 12 FLAC) vers un iPod simulé (`init-sim`, modèle 5G) :
- **macOS** : 47 pistes, 6 pochettes uniques, ~16 s ; la deuxième sync ne copie rien.
- **Linux** (Fedora 44) : idem avec ffmpeg ; ~57 s, parce que les sources sont lues sur le partage Parallels.
- **Windows 11 ARM** : sans ffmpeg, 35 pistes copiées et 12 FLAC en échec avec un message clair ; avec ffmpeg (winget `Gyan.FFmpeg`, x64 émulé), les 47 pistes en 125 s, conversions comprises ; la deuxième sync ne copie rien (1,2 s). Le dossier source peut être un partage réseau (`\\serveur\partage\Musique`).

`list`, `watch` et `eject` n'ont pas pu être essayés avec un vrai iPod dans les VM (pas de passage USB d'iPod). À faire en priorité : voir [[DeviceKit]].
