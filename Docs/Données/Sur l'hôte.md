# Sur l'hôte

**La bibliothèque est liée à l'ordi.** Chaque ordi a la sienne, lue sur son disque local. C'est ce qui garantit la réactivité actuelle. Décision : [[ADR-001 Bibliothèque sur l'hôte, données de l'iPod sur l'iPod]].

## Emplacements
| | macOS | Windows | Linux |
|---|---|---|---|
| Données | `~/Library/Application Support/iPod Pro Max` | `%APPDATA%\iPod Pro Max` | `$XDG_DATA_HOME/ipod-pro-max` (`~/.local/share`) |
| Caches | `~/Library/Caches/iPod Pro Max` | `%LOCALAPPDATA%\iPod Pro Max\Cache` | `$XDG_CACHE_HOME/ipod-pro-max` |

## Données (à conserver)
- `library.json` : pistes, playlists, dossiers sources (`musicFolderPath`, `audiobooksFolderPath`), sélection de photos. Chaque piste gagne une [[Empreinte audio]].
- `Artwork/` : pochettes de la bibliothèque, adressées par contenu.
- `Artist Photos/` : photos Deezer et `index.json`.
- `host.json` : l'identifiant stable de cet ordi (UUID généré une fois) et son nom. Il sert au [[Manifeste et propriété des pistes]].

## Caches (reconstructibles, donc jetables)
- `Transcodes/` (14 Go aujourd'hui), `PhotoCache/`, épisodes de podcast téléchargés en attente de sync.
- Ils quittent `Application Support` pour le dossier de cache de l'OS. Voir [[ADR-004 Caches sur l'hôte]].

## Ce qui n'est plus ici
`deviceRecords` (options de sync par iPod), les réglages et les abonnements podcast vont [[Sur l'iPod]]. Voir [[Migration]].

## Réactivité
Rien ne change par rapport à aujourd'hui : chargement de `library.json` depuis le SSD, sauvegarde différée (`scheduleSave`), refus d'écraser un fichier non vide par un document vide (`saveNow`).
