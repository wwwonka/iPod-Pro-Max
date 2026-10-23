# Onglet iPod

Comme dans iTunes : sous l'iPod dans la sidebar, on voit **tout ce qui est réellement sur l'appareil**, quel que soit l'ordi qui l'y a mis, et on peut le gérer.

## Ce qu'on voit
- Musique, Vidéos, Podcasts, Livres audio et Playlists de l'iPod. On réutilise **les mêmes vues** que la bibliothèque (par artiste ou tableau triable), alimentées par le DB de l'iPod plutôt que par `library.json`.
- Pour chaque piste, une pastille de provenance : « cet ordi », « MacBook de Julien » (un autre ordi, d'après le [[Manifeste et propriété des pistes]]) ou « inconnu ».
- Les compteurs de lecture, la note et la date du dernier passage lus sur l'iPod.

## Ce qu'on peut faire
- **Modifier les tags** : on réécrit seulement l'iTunesDB, le fichier audio n'est pas touché.
- **Supprimer** des pistes ou des playlists, y compris celles d'un autre ordi. C'est explicite, avec confirmation.
- **Copier vers la bibliothèque de cet ordi** : on récupère le fichier depuis l'iPod et on l'importe. Comme on ne gère que des iPod sans DRM, c'est possible.
- Glisser des pistes de la bibliothèque vers l'onglet iPod : c'est le glisser-vers-l'iPod existant.

## Comment
- Lecture : `ITunesDBReader` (existant) et `ArtworkDB` pour les pochettes. Le chargement se fait au montage, en arrière-plan, et le résultat est gardé en mémoire.
- Écriture : `ITunesDBWriter` et `Hash58` (existants), mis en file avec les syncs dans `SyncCoordinator`. On n'écrit jamais deux fois en même temps sur le DB.
- Les modifications sont groupées : plusieurs modifications rapides donnent une seule réécriture du DB.

Livré en phase 2, **dans l'app SwiftUI actuelle**, avant toute la partie multiplateforme. Voir [[Phases]].
