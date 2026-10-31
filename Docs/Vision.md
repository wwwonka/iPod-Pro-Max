# Vision

## Ce qu'on veut
- **Portable.** Le dossier `iPod Pro Max/` sur l'iPod contient l'app pour les trois OS. On branche l'iPod sur n'importe quel ordi, on lance, et on synchronise.
- **Multiplateforme.** macOS, Windows et Linux depuis **une seule base de code Swift**. Voir [[Compilation multiplateforme]].
- **Belle, look Mac partout.** Native sur Mac, et « Mac-like » sur Windows et Linux grâce au [[Thème GTK Mac]].
- **Aussi réactive qu'aujourd'hui.** Aucune lecture sur le disque de l'iPod dans le chemin critique de l'interface. Voir [[Sur l'hôte]].
- **Comme iTunes, en mieux.** L'[[Onglet iPod]] montre et modifie ce qui est réellement sur l'appareil.

## Ce que l'app est aujourd'hui
- L’application principale est SwiftCrossUI dans `iPod Pro Max/` : bibliothèque, navigation, recherche, détection des iPods, page appareil (éjection). Sync, Import et Forget ne sont pas encore branchés. Voir [[Application SwiftCrossUI]].
- Le noyau portable (`iPodKit`, `MediaKit`, `DeviceKit`) et la CLI `ipodpromax` compilent sur macOS, Linux et Windows. Voir [[Package Swift]].
- L’ancienne app Mac SwiftUI est conservée dans `Refs/SwiftUI/` comme référence de portage.
- Le format iTunesDB est implémenté en Swift pur, sans libgpod.
- Les données de l’hôte restent dans `~/Library/Application Support/iPod Pro Max` (`library.json`, pochettes, caches, podcasts, transcodes).

## Principes de performance (repris de `AGENTS.md`, valables sur les 3 OS)
- **Tous les cœurs pour le travail lourd.** Fenêtre glissante `withTaskGroup` dimensionnée par `activeProcessorCount`.
- **Le thread principal reste libre.** Mises à jour de l'état observé groupées toutes les ~500 ms.
- **Zéro travail au repos.** Pas de timer ni de polling, y compris pour la détection d'iPod sur Windows et Linux (voir [[DeviceKit]]).
- **Mesurer, ne pas deviner.** `Tools/DbTest/run.sh --import-bench` sert de référence : 8,7 s pour 5 299 fichiers. Aucune phase ne doit faire régresser ce chiffre.

## Non-objectifs
- Les iPod nano 5G et plus, shuffle et touch (hash72/hashAB) : hors périmètre, comme aujourd'hui.
- Une interface identique au pixel près au Mac sur Windows et Linux : on vise « Mac-like », voir [[ADR-003 GTK et thème Mac sur Windows et Linux]].
- L'import depuis Musique ou Photos d'Apple ailleurs que sur Mac : ces frameworks n'existent pas sur les autres OS.
