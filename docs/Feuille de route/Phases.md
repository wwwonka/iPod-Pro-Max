# Phases

Estimation en semaines de travail concentré, solo avec Claude. **Total : environ 21 à 24 semaines.** Les phases 1 et 2 (5 semaines) apportent déjà de la valeur sur Mac seul.

## Phase 0 : prototypes (1 sem.)
Valider les trois inconnues qui peuvent tuer le projet. Détail : [[Prototypes phase 0]].
- [ ] Vue Musique en SwiftCrossUI avec le [[Thème GTK Mac]], sur AppKit, GTK Linux et GTK Windows
- [ ] `.exe` + DLL GTK lancé depuis une clé FAT32 sur un Windows vierge
- [ ] App Mac téléchargée, copiée sur l'iPod, lancée sur un autre Mac
- **Sortie** : décision « on continue » ou « on ajuste » [[ADR-002 SwiftCrossUI comme code d'interface unique]].

## Phase 1 : iPodKit (2 sem.)
- [ ] Créer `Package.swift` et la cible iPodKit (voir [[Modules]])
- [ ] `Hash58` : CryptoKit → swift-crypto
- [ ] `ArtworkDB` / `PhotoDB` : `CGImage` → `PixelBuffer`, encodage en Swift pur
- [ ] Le projet Xcode consomme iPodKit comme package local
- [ ] Tests de référence et CI Linux (voir [[CI et packaging]])
- **Sortie** : DB identique octet pour octet entre Mac et Linux en CI ; l'app Mac fonctionne comme avant.

## Phase 2 : données sur l'iPod, manifeste, onglet iPod, sur Mac (3 sem.)
- [ ] `DeviceStore` : `Data/settings.json`, `device.json`, `podcasts.json` (voir [[Sur l'iPod]])
- [ ] [[Manifeste et propriété des pistes]] et nouvelles règles de sync
- [ ] [[Empreinte audio]] à l'import et en arrière-plan
- [ ] [[Migration]] et caches déplacés vers `~/Library/Caches`
- [ ] [[Onglet iPod]]
- **Sortie** : `dbtest --import-bench` sans régression (≤ 8,7 s + 10 %) ; données de l'iPod lues en moins de 300 ms après le montage ; sync depuis deux Mac sans perte ni doublon.

## Phase 3 : AppModel (2 sem.)
- [ ] Sortir la logique de `LibraryStore`, `ContentView` et `MusicView` vers AppModel, sans AppKit
- [ ] `OSAllocatedUnfairLock` → `Synchronization.Mutex`
- **Sortie** : AppModel compile sur Linux ; l'app SwiftUI s'appuie dessus sans régression.

## Phase 4 : DeviceKit, MediaKit portable, CLI (3–4 sem.)
- [ ] [[DeviceKit]] Linux et Windows : événements, numéro de série USB, éjection
- [ ] [[MediaKit]] portable : lecteur de tags Swift, pochettes et transcodage via ffmpeg
- [ ] CLI `ipodpromax sync <dossier>` pour Linux et Windows
- **Sortie** : un iPod classic synchronisé depuis Linux et depuis Windows, lu correctement par l'iPod.

## Phase 5 : AppUI (8–10 sem.)
- [ ] Contributions SwiftCrossUI (voir [[Manques SwiftCrossUI]])
- [ ] [[Thème GTK Mac]]
- [ ] Écrans dans l'ordre : sidebar et appareil, Musique, onglet iPod, Playlists, Podcasts, Livres audio, Vidéos, Photos (Mac seulement), Réglages
- [ ] Bascule de l'app Mac vers AppUI une fois la parité atteinte
- **Sortie** : vue Musique avec multisélection, tri et glisser-déposer sur AppKit et GTK ; captures validées sur les 3 OS.

## Phase 6 : distribution (2 sem.)
- [ ] GitHub Actions sur 3 OS et assemblage (voir [[CI et packaging]])
- [ ] Lanceurs « shadow copy » (voir [[Lancement portatif par OS]])
- [ ] Mise à jour de l'app sur l'iPod depuis l'app ; mise à jour de yt-dlp
- [ ] Licence ffmpeg tranchée
- **Sortie** : un iPod préparé depuis le zip de release se lance et synchronise sur un Mac, un PC et un Linux vierges.
