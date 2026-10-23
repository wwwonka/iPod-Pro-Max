# Historique des décisions

Comment on est arrivé au plan actuel, et pourquoi certaines options ont été écartées. Discussion du 2026-10-22.

## 1. Le plan d'origine (proposé par une autre IA)
- **Architecture** : extraire Core et Sync dans un package « iPodKit » sans dépendance Apple ; sortir la logique d'interface ; détection d'iPod par OS ; **ffmpeg partout** à la place d'AVFoundation et de VideoToolbox.
- **Interface** : SwiftUI sur Mac, SwiftCrossUI (WinUI / GTK) sur Windows et Linux.
- **Mode portatif** : un dossier `iPod Pro Max/` sur l'iPod, FAT32 obligatoire, **bibliothèque sur l'iPod comme source de vérité**, pistes identifiées par empreinte, profils d'hôte, lanceur Linux, signature ad hoc sur Mac.
- **Ordre** : iPodKit, puis bibliothèque sur l'iPod, puis CLI, puis interfaces.
- **Outillage** : un repo, un `Package.swift`, GitHub Actions.

## 2. La critique, et ce que chaque point est devenu
| Point soulevé | Devenu |
|---|---|
| Modèle de données ambigu : l'iPod est-il la bibliothèque, ou son miroir ? | Bibliothèque sur l'hôte, voir [[ADR-001 Bibliothèque sur l'hôte, données de l'iPod sur l'iPod]] |
| Un iPod partagé entre ordis : la sync de B efface ou duplique la musique de A | [[Manifeste et propriété des pistes]], [[Empreinte audio]] |
| On ne peut pas éjecter l'iPod pendant que l'app y tourne | Lanceur « shadow copy » sur les 3 OS, voir [[Lancement portatif par OS]] |
| « Copiée soi-même = pas de quarantaine » est faux : les fichiers `._` sur FAT32, la translocation | [[Lancement portatif par OS]] |
| WinUI exige le Windows App Runtime sur l'hôte | GTK sur Windows, voir [[ADR-003 GTK et thème Mac sur Windows et Linux]] |
| Un binaire Linux entièrement statique ne peut pas charger GTK ; `showexec` sur vfat | stdlib statique + GTK dynamique ; `lancer.sh`, voir [[Lancement portatif par OS]] |
| ffprobe par fichier ruinerait l'import en 8,7 s | Chemins rapides Apple conservés sur Mac ; lecteur de tags en Swift pur ailleurs, voir [[MediaKit]] |
| Les pochettes : le décodage est oublié, pas seulement l'encodage | [[MediaKit]] |
| Dépendances Apple oubliées (`os`, AppKit, CryptoKit dans d'autres fichiers…) | [[Modules]] |
| FireWire GUID hors Mac, chemin critique pour hash58 | [[DeviceKit]] |
| La conversion HFS+ → FAT32 est en fait une restauration | [[ADR-005 FAT32 en mode portatif]] |
| FAT32 : 4 Go, pas de journal | [[Sur l'iPod]], [[Risques]] |
| yt-dlp qui vieillit, licence ffmpeg | [[CI et packaging]] |
| L'interface arrive trop tard alors que c'est le plus gros risque | [[Prototypes phase 0]] |

## 3. Les choix de l'utilisateur, dans l'ordre
1. Tout ce qui est dans Application Support devrait aller sur l'iPod, sans perdre en réactivité. *Première version : bibliothèque sur l'iPod, avec un miroir local et une écriture différée.*
2. La bibliothèque est liée à l'ordi hôte. **Nouvel onglet iPod** façon iTunes pour parcourir, modifier et supprimer (voir [[Onglet iPod]]).
3. La documentation va dans le repo (`docs/`), sous forme de vault Obsidian.
4. Demande d'exemples d'apps SwiftCrossUI. Constat : `MusicPlayerExample` est la seule vitrine ; `Table` n'a ni sélection ni tri, et il n'y a pas de glisser-déposer (voir [[Manques SwiftCrossUI]]).
5. « swift-winrt et adwaita-swift seraient mieux ? » *Version intermédiaire : un toolkit natif par OS.*
6. Finalement : **« la bibliothèque est liée à l'hôte »** (confirmé) et **« un feel surtout Mac sur toutes les plateformes, et que le code sache se compiler pour les autres plateformes »**. Version finale : SwiftCrossUI comme code unique, AppKit sur Mac, GTK4 avec [[Thème GTK Mac]] ailleurs (voir [[ADR-002 SwiftCrossUI comme code d'interface unique]]).

## 4. Options écartées
- **Bibliothèque sur l'iPod** : écrites sur un disque dur lent et en veille, avec des chemins sources qui n'existent que sur un ordi.
- **ffmpeg partout** : trop lent pour lire les tags, et on perdrait VideoToolbox et ImageIO sur Mac.
- **SwiftUI sur Mac + SwiftCrossUI ailleurs** : deux codes d'interface.
- **WinUI 3 direct (swift-winrt) + adwaita-swift** : la meilleure intégration par OS, mais trois codes et un look Windows ou GNOME, pas Mac.
- **WinUI via SwiftCrossUI** : exige le Windows App Runtime, et donne un look Windows.
- **Flutter ou Electron** : look Mac plus fidèle, mais il faut quitter Swift et réécrire l'app.

Retour au [[README]].
