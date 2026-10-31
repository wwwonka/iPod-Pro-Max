# ADR-006 Noyau portable sans dépendance Apple

- **Statut** : acceptée, le 2026-10-30
- **Contexte** : iPodKit, MediaKit et DeviceKit (voir [[Modules]]) devaient compiler sur macOS, Linux et Windows, produire les mêmes bases de données partout, et garder sur Mac les chemins rapides d'AVFoundation et d'ImageIO. Le plan prévoyait swift-crypto, deux cibles MediaKitApple et MediaKitPortable, et des API système par OS. La mise en œuvre a précisé ou changé plusieurs points.
- **Décisions** :
  1. **SHA-1 en Swift pur plutôt que swift-crypto.** hash58 ne hache qu'une base par sync. swift-crypto embarque BoringSSL, long à compiler sous Windows ARM, pour une seule fonction. Un test vérifie l'égalité avec CryptoKit sur Mac.
  2. **Mise à l'échelle des images en Swift pur, avec des poids entiers, sur les 3 OS, Mac compris.** Seul le décodage reste propre à l'OS : ImageIO sur Mac, swift-image-formats ailleurs (déjà tiré par SwiftCrossUI). Ainsi les vignettes sont identiques octet pour octet partout. Si le Mac gardait CoreGraphics, deux syncs du même iPod depuis deux OS différents réécriraient des pochettes différentes.
  3. **Une seule cible MediaKit**, avec `#if canImport(AVFoundation)` autour des fichiers Apple, au lieu de deux cibles. Le lecteur de tags portable se compile aussi sur Mac, ce qui permet de le comparer à AVFoundation (`ipodpromax tags --bench`).
  4. **Lecteur de tags en Swift pur hors Mac** (ID3, MP4, FLAC, Ogg, WAV, AIFF). Mesuré : 3,6 fois plus rapide qu'AVFoundation sur 5 300 fichiers, et jamais moins complet. Le Mac garde AVFoundation pour l'instant (pas de changement de comportement de l'app) ; passer le Mac au lecteur portable est une option à évaluer, vu les erreurs d'AVFoundation relevées dans [[Package Swift]].
  5. **DiskArbitration plutôt qu'AppKit** pour les événements et l'éjection sur Mac : DeviceKit ne dépend pas d'AppKit et le CLI s'en sert.
  6. **Sous Windows, le code Plug and Play est écrit en C** (cible `CWinDevices`). Le module WinSDK de Swift n'inclut pas cfgmgr32, et importer `cfgmgr32.h` comme second module Clang entre en conflit avec WinSDK (`devpropdef.h`). L'en-tête C n'expose que des types simples.
  7. **Événements sans polling partout** : DiskArbitration (Mac), `poll()` sur `/proc/self/mountinfo` (Linux), `CM_Register_Notification` (Windows, sans fenêtre cachée).
  8. **Tri des index de la base sans locale**, pour que la même bibliothèque donne la même base sur tous les ordis.
  9. **Le registre de sync du CLI est sur l'iPod** (`iPod Pro Max/Data/cli-sync.json`), conformément à [[ADR-001 Bibliothèque sur l'hôte, données de l'iPod sur l'iPod]]. Dates encodées exactement : une date ISO 8601 perd les fractions de seconde et faisait recopier les pistes à paroles à chaque sync.
- **Conséquences** :
  - les tests de référence passent à l'identique sur les 3 OS ;
  - les pochettes écrites par l'app Mac changent très légèrement (autre filtre de mise à l'échelle) ; dimensions et marges sont les mêmes ;
  - l'API des modules est `public`, ce qui oblige l'app à `import` les modules une fois branchée sur le package.

Voir [[Package Swift]], [[MediaKit]], [[DeviceKit]], [[CLI ipodpromax]].
