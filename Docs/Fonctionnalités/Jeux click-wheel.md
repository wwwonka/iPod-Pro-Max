# Jeux click-wheel

La section **Jeux** affiche les jeux iPod (`.ipg`) des dossiers choisis, par exemple `iTunes Media/iPod Games`. Ce sont notamment ceux du projet de préservation *ipodclickwheelgamespreservationproject*. Elle reprend la grille des Albums.

## Ce qu'on voit
- Une tuile par jeu, au format 4:3 de sa pochette, avec le titre et l'éditeur.
- Le bouton « Add Folder… », et un bouton « Remove » par dossier. Les dossiers sont des `KnownSource` de type `games` dans `known_hosts.json`.
- Un double-clic ouvre les **instructions** du jeu dans un petit panneau façon Quick Look :
  - pas de barre de titre, apparition et disparition en fondu ;
  - fermeture par Échap ou par un clic à l'extérieur ;
  - défilement ;
  - zoom au trackpad pour agrandir seulement : impossible de descendre sous la largeur de la fenêtre.
- Cmd-A sélectionne tous les jeux, et on peut les glisser sur un iPod.

## Ce qu'on ne peut pas encore faire : installer sur l'iPod
Un jeu copié sur l'iPod ne démarre pas sans l'autorisation `iPod_Control/Device/IC-Info.sidb`, et seul iTunes écrit ce fichier. Nous l'avons analysé :
- un en-tête de 4 octets, `00 06 00 02` ;
- puis 13 232 octets (827 × 16) chiffrés, d'entropie 7,98.

Il n'y a rien d'exploitable sans la clé. Déposer des jeux sur un iPod affiche donc un message au lieu de copier des fichiers qui ne démarreraient pas.

Piste pour la suite :
1. Autoriser l'iPod une fois avec iTunes, par exemple dans une VM.
2. Relever, sur un iPod où iTunes a installé un jeu, l'emplacement des fichiers et ce qu'iTunes ajoute dans l'iTunesDB.
3. Reproduire cette copie dans l'app, en préservant `IC-Info.sidb`.

## Comment
- **Lecture des archives** : `GameCatalog`. Un `.ipg` est un zip ; on n'en lit que :
  - `iTunesArtwork`, la pochette JPEG 320×240 ;
  - `iTunesMetaData`, les atomes MP4 `©nam`, `aART`, `©day` et `©gen`.
- **Lecteur zip** : `ZipArchive.read(from:where:)` projette le fichier en mémoire (mmap) et ne décompresse que les entrées demandées. Un jeu de 60 Mo ne coûte que quelques pages.
- **Parallélisme** : la lecture se fait sur une fenêtre de tâches, une par cœur.
- **Cache des pochettes** : `Persistent Data/UI Cache/Game Artwork`, avec une clé qui dépend du nom, de la taille et de la date du fichier.
- **Instructions** : l'image vient de `Resources/<langue>/` ; c'est celle que nomme l'attribut `url` de `Description.xml`. La langue est celle du système, sinon l'anglais. L'image est extraite une seule fois dans `Game Artwork/Instructions`. Le panneau qui l'affiche est `QuickPreview`, dans `Platforms/`.
- **Glisser vers l'iPod** : `TrackDrag.beginGames`. Le contenu transporté est la liste des chemins des archives, transmise à `TrackDrag.onGamesDropped`.

## Une seule grille pour toutes les sections
Albums et Jeux sont deux configurations de la même page, `GridPage` (`UI/GridPage.swift`), et non deux copies. Une modification de la grille vaut donc partout. Seules trois choses varient d'une section à l'autre :
- `GridSection` : la clé de la section, la taille par défaut et le format des pochettes (`albums` est carré, `games` est en 4:3) ;
- `GridAction` : ce que fait un clic. `.expand` déplie l'album avec ses pistes et permet la lecture ; `.open` sélectionne au clic et ouvre au double-clic ;
- les éléments affichés.

Le zoom au pincement, son enregistrement, Cmd-A, le glisser et le rendu (`AlbumBrowser`) sont écrits une seule fois.

Pour le pincement, la hiérarchie SwiftCrossUI interceptait les événements de geste avant la grille. `AlbumCollectionView` les capte donc avec un moniteur local `.magnify`, limité à sa zone visible.

Le zoom est enregistré par section dans `settings.json`, sous la forme `gridArtworkSizes: { "albums": …, "games": … }`. Les anciennes clés `albumArtworkSize` et `gameArtworkSize` sont reprises au chargement.

Pour l'instant, un jeu est représenté par un `AlbumInfo` sans pistes. Le dépliage, la lecture et le glisser de pistes dépendent de ce type. Un modèle d'élément neutre viendra quand une troisième section en grille en aura besoin.

## État
- Livré sur macOS.
- Linux et Windows : les paramètres `artworkAspect` et `onOpen` existent, mais ces versions ne sont ni compilées ni testées. En GTK, les tuiles restent carrées. Le panneau d'instructions y ouvre la visionneuse du système.
