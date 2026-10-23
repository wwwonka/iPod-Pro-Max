# Vision

## Ce qu'on veut
- **Portable.** Le dossier `iPod Pro Max/` sur l'iPod contient l'app pour les trois OS. On branche l'iPod sur n'importe quel ordi, on lance, et on synchronise.
- **Multiplateforme.** macOS, Windows et Linux depuis **une seule base de code Swift**. Voir [[Compilation multiplateforme]].
- **Belle, look Mac partout.** Native sur Mac, et « Mac-like » sur Windows et Linux grâce au [[Thème GTK Mac]].
- **Aussi réactive qu'aujourd'hui.** Aucune lecture sur le disque de l'iPod dans le chemin critique de l'interface. Voir [[Sur l'hôte]].
- **Comme iTunes, en mieux.** L'[[Onglet iPod]] montre et modifie ce qui est réellement sur l'appareil.

## Ce que l'app est aujourd'hui
- Une app Mac SwiftUI d'environ 11 000 lignes : `Core/`, `Device/`, `Library/`, `Sync/` et `UI/`.
- Le format iTunesDB est déjà implémenté en Swift pur, sans libgpod.
- Les données sont dans `~/Library/Application Support/iPod Pro Max` : `library.json` 3,6 Mo, `Artwork` 58 Mo, `Artist Photos` 10 Mo, `PhotoCache` 115 Mo, `Podcasts` 5,3 Go, `Transcodes` 14 Go. Les réglages sont dans `UserDefaults` / `@AppStorage`.

## Principes de performance (repris de `CLAUDE.md`, valables sur les 3 OS)
- **Tous les cœurs pour le travail lourd.** Fenêtre glissante `withTaskGroup` dimensionnée par `activeProcessorCount`.
- **Le thread principal reste libre.** Mises à jour de l'état observé groupées toutes les ~500 ms.
- **Zéro travail au repos.** Pas de timer ni de polling, y compris pour la détection d'iPod sur Windows et Linux (voir [[DeviceKit]]).
- **Mesurer, ne pas deviner.** `Tools/dbtest/run.sh --import-bench` sert de référence : 8,7 s pour 5 299 fichiers. Aucune phase ne doit faire régresser ce chiffre.

## Non-objectifs
- Les iPod nano 5G et plus, shuffle et touch (hash72/hashAB) : hors périmètre, comme aujourd'hui.
- Une interface identique au pixel près au Mac sur Windows et Linux : on vise « Mac-like », voir [[ADR-003 GTK et thème Mac sur Windows et Linux]].
- L'import depuis Musique ou Photos d'Apple ailleurs que sur Mac : ces frameworks n'existent pas sur les autres OS.
