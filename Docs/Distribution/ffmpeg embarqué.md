# ffmpeg embarqué

**Règle : l'utilisateur n'installe jamais rien.** Ce dont l'app a besoin voyage avec elle. ffmpeg en fait partie : il est compilé par nous et posé à côté de l'exécutable. MediaKit ne cherche plus jamais un ffmpeg du système (ni le `PATH`, ni Homebrew), pour que tout le monde ait la même version.

## Un ffmpeg minimal, à nous
`Tools/FFmpeg/build.sh` le compile à partir des sources officielles, figées par version et empreinte SHA-256, avec **seulement** ce que la sync utilise :
- lecture des formats courants (MP3, AAC, ALAC, FLAC, Vorbis, Opus, WMA, AC-3, WAV, AIFF ; H.264, HEVC, MPEG-4, VP8/9, WMV…) ;
- encodage AAC, et H.264 par l'encodeur **du système** quand il existe : VideoToolbox sur Mac, Media Foundation sous Windows ; OpenH264 (BSD, compilé depuis les sources) sous Linux ;
- conteneur MP4/M4V/M4B, chapitres (livres audio), image d'aperçu JPEG, mise à l'échelle.

Licence LGPL, sans aucune partie GPL ni non libre ; un `LICENSE.md` accompagne chaque binaire.

| | Taille | Dépend de |
|---|---|---|
| macOS (universel arm64 + x86_64) | 12 Mo (5 + 7) | rien d'autre que macOS |
| Linux arm64 | 5,8 Mo | libc, libm, zlib (présentes partout) |
| Windows arm64 / x64 | 5,0 / 7,0 Mo | rien d'autre que Windows |

À comparer aux builds « complets » publiés (BtbN) : 80 à 130 Mo pour le seul exécutable, et des versions « latest » remplacées en continu.

`Tools/FFmpeg/check.sh <ffmpeg> …` vérifie un binaire sur tous les usages de MediaKit : FLAC → AAC, vidéo pour l'iPod avec progression, image d'aperçu, fusion de livre audio avec chapitres. Passé sur Mac et Linux le 2026-10-30. Sous Windows 11 ARM, sans aucun ffmpeg installé : sync FLAC → AAC et vidéo par Media Foundation (H.264 Baseline 320×180, AAC stéréo).

## Où il est rangé
MediaKit (`FFmpeg.binaryPath()`) cherche, dans l'ordre : `IPODPROMAX_FFMPEG`, à côté de l'exécutable (là où le build le pose, pour l'app comme pour la CLI : voir [[Sur l'iPod]]), un dossier `Tools/<OS>/` proche, puis, pour le développement, `.build-work/FFmpeg/<os>-<arch>/` dans le repo (sortie de `Tools/FFmpeg/build.sh`). Le ffmpeg Mac vise macOS 10.15, comme l'app ; les ffmpeg Linux se compilent dans le conteneur Docker du build Linux.
- **App Mac (Xcode)** : phase « Embed ffmpeg » qui copie le binaire universel dans `Contents/MacOS` ; Xcode le signe avec l'app.
- **Prototype** : `build.sh` le pose à côté de l'exécutable sur les trois OS.
- **CLI** : `ipodpromax info` affiche le ffmpeg utilisé.

Les binaires ne sont pas dans git : on les reconstruit (`Tools/FFmpeg/build.sh`, puis `build.sh windows` depuis Linux, avec la chaîne de compilation llvm-mingw, elle aussi figée par version et empreinte). La machine de build a besoin de `make`, `gcc`/`g++`, de la bibliothèque C++ statique et de `nasm` ; l'utilisateur, de rien.

## Reste à faire
- **Linux ancien** : compiler dans un conteneur d'une vieille distribution, pour une glibc ancienne (voir [[Compilation multiplateforme]]).
- **Licence** : OpenH264 compilé par nous n'est pas couvert par la licence de brevets que Cisco offre pour ses propres binaires ; à trancher avec la carte « Licence ffmpeg tranchée ».

Voir [[MediaKit]], [[CLI ipodpromax]].
