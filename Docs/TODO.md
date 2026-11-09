# Plan d'implémentation : sections de base d'iPod Pro Max

## Contexte
Julien a défini les sections de l'app : Music, Podcasts, Audiobooks, Videos, Photos, plus les fenêtres Settings et Metadata Editor. Ce plan donne un avis sur cette structure puis un ordre d'implémentation par étapes. Chaque étape sort sur macOS, Windows et Linux ensemble, et respecte les principes de performance d'AGENTS.md (tous les cœurs, main thread libre, zéro travail au repos).

État actuel du dépôt (vérifié) : `AudiobooksView`, `PodcastsView`, `PhotosView`, `PhotoInventory`, sidebar sur 3 plateformes, commit « video sections and video playlists », `TrackTable`, `AlbumBrowser`, `ArtistList`. Cartes déjà au Project : empreinte audio, mise à jour de yt-dlp, artistes Deezer, MediaKit portable. On construit donc sur de l'existant et non à partir de zéro.

## ÉTAPE 1 : FAITE (2026-11-09) : fenêtre Préférences, ⌘,
Voir [[Fenêtre des préférences]] : scène `Window`, verre de la fenêtre principale, onglets General, Playback, Syncing, Devices, Plug-ins et Advanced, plusieurs dossiers par section (dont quatre types de vidéo), sélecteur depuis Settings, dossiers persistés dans `known_hosts.json` et bibliothèque alignée sur eux. Reste : onglets vides à remplir, import des dossiers vidéo, glyphes Windows et Linux.

## Révision après retour de Julien (prioritaire sur le reste)
- **Tout service externe est un plug-in** : Spotify, YouTube Music, Apple Music, Deezer, Soulseek, torrent, yt-dlp, Musixmatch/LRCLIB, MusicBrainz, Ohdio, Pinterest, Apple Photos. Le cœur de l'app reste lean et ne connaît que des protocoles.
- **Architecture proposée : plug-ins hors processus.** Un plug-in = un dossier avec `plugin.json` (id, version, capacités, réglages déclarés) et un exécutable qui dialogue en JSON lignes sur stdin/stdout. Avantages : indépendant du langage (Swift, Python, Node, Go), pas de problème d'ABI ni de chargement dynamique sur 3 OS, un plug-in qui plante n'abat pas l'app, communauté libre d'en écrire, zéro coût au repos (processus lancé à la demande). Les plug-ins vivent sur l'iPod (cohérent avec « les données restent sur l'iPod »).
- **Les réglages d'un plug-in sont décrits dans son manifeste** et rendus automatiquement par la fenêtre Préférences (champs, clés d'API, bascules) : la fenêtre ne change pas quand un plug-in s'ajoute.
- **Nouvel ordre** : (A) Préférences, (B) Metadata Editor, (C) contrat de plug-ins + premier plug-in (le scraper Spotify existant de Julien), puis les sections Music, Playlists, Podcasts, etc. Les étapes 0 à 5 ci-dessous se lisent donc dans l'ordre : fondations plug-ins minimales → Préférences → Metadata Editor → reste.
- Question ouverte : où est le scraper Spotify (langage, dépôt) ? Il servira de plug-in de référence pour figer le contrat.

## Avis sur le plan
Ce qui est bien :
- Les 5 familles correspondent aux contenus qu'un iPod classique sait lire (musique, podcasts, livres audio, vidéos, photos). La structure colle au matériel.
- Séparer UI (comme Apple Music/iTunes) et Backend (sources, téléchargement, métadonnées) est la bonne coupe. Les plugins deviennent des modules indépendants.
- Metadata Editor (cmd+i) et Settings en fenêtres séparées : bon choix.

Points d'attention :
1. **Juridique et ToS** : Spotify et YouTube Music n'autorisent pas le téléchargement. Le plugin doit rester une source de playlists (titres, artistes, albums), puis un résolveur trouve l'audio ailleurs. Soulseek, torrents et yt-dlp relèvent de la responsabilité de l'utilisateur ; à garder derrière un réglage explicite dans Settings.
2. **Soulseek et torrent** : pas d'API officielle simple. Recommandation : piloter un démon externe (slskd pour Soulseek, aria2 ou transmission pour les torrents) au lieu de réimplémenter les protocoles. Cela évite une grosse dépendance native sur 3 OS.
3. **Lyrics** : l'API gratuite de Musixmatch est limitée (extrait seulement). LRCLIB est gratuit, sans clé, avec paroles synchronisées ; Musixmatch devient un fournisseur optionnel avec clé personnelle.
4. **Metadata Finder** : MusicBrainz + Cover Art Archive (ouvert, gratuit) comme base, AcoustID pour l'empreinte (déjà prévue au Project), Deezer pour les photos d'artistes (déjà utilisé), iTunes Search API pour les pochettes. Discogs en option.
5. **Podcasts** : RSS natif d'abord. YouTube chaîne/playlist en podcast passe par yt-dlp (déjà prévu). Ohdio n'a pas d'API publique : scraping fragile, à faire en dernier.
6. **Photos** : l'import depuis Apple Photos (PhotoKit) n'existe que sur macOS ; Windows et Linux n'auront qu'un import de dossiers. Pinterest n'a pas de téléchargement officiel : plugin à part, optionnel, en dernier.
7. **Smart playlists** : l'iPod classique ne les évalue pas toutes ; les évaluer côté hôte et écrire le résultat en playlist (à confirmer avec iPodKit).

## Étapes (chacune livrable seule, sur les 3 OS)

**Étape 0 : Fondations**
- Sidebar pilotée par des données (enum de sections + descripteurs) au lieu de code par section ; fichiers : `UI/Sidebar.swift`, `SidebarMac/Gtk/WinUI`.
- Protocole `PlaylistSource` / `Downloader` / `MetadataProvider` / `LyricsProvider` dans un module partagé (MediaKit), avec registre de plugins.
- File de tâches longues (téléchargements, imports) : actor + progression groupée toutes les ~500 ms, sliding window `activeProcessorCount` (modèle : `LibraryStore.importFiles` dans `Refs/SwiftUI/`).
- Squelettes des fenêtres Settings et Metadata Editor.

**Étape 1 : Music, cœur**
Recently Added, Albums, All Songs (une bonne partie existe) puis Favorites (champ favori/note persisté). Vérifier les perfs avec `Tools/DbTest/run.sh ... --import-bench`.

**Étape 2 : Playlists**
Playlists, dossiers de playlists, smart playlists (moteur de règles évalué hors main thread, résultat écrit en playlist statique).

**Étape 3 : Metadata Editor (cmd+i)**
Édition simple et multiple, pochette, onglet paroles ; écriture des tags via MediaKit ; mise à jour de la bibliothèque sans rescan complet.

**Étape 4 : Metadata Finder + Lyrics**
MusicBrainz/CAA/AcoustID puis LRCLIB ; Musixmatch en option. Branché sur le Metadata Editor (« Chercher »).

**Étape 5 : Settings**
Comptes des plugins, clés d'API, dossiers, activation des sources de téléchargement, avertissement légal.

**Étape 6 : Téléchargement**
yt-dlp d'abord (fallback, déjà planifié), puis Soulseek via slskd, puis torrents via aria2. Résolveur : titre/artiste → meilleure source → import + tags.

**Étape 7 : Playlists Internet**
Spotify, puis YouTube Music, puis Apple Music et Deezer. Chaque plugin = import de playlist + résolution via l'étape 6.

**Étape 8 : Podcasts**
Abonnements RSS, Recently Updated, épisodes, sync vers l'iPod ; puis YouTube chaîne/playlist ; Ohdio en dernier.

**Étape 9 : Audiobooks**
Audiobooks et Authors, formats m4b/m4a avec chapitres, signet de lecture compatible iPod.

**Étape 10 : Videos**
Movies, TV Shows (déjà amorcés) puis Music Videos ; métadonnées via un fournisseur de films/séries (TMDB à confirmer).

**Étape 11 : Photos**
All Photos et Folders (base `PhotoInventory`), import d'un dossier sur les 3 OS ; import Apple Photos sur macOS ; plugin Pinterest en dernier.

## Décisions à trancher avec Julien
1. Soulseek/torrent : démon externe (recommandé) ou implémentation native ?
2. Lyrics : LRCLIB par défaut + Musixmatch optionnel, d'accord ?
3. Smart playlists : évaluées côté hôte puis figées, d'accord ?
4. Pinterest et Ohdio : on les garde, sachant qu'ils sont fragiles ?
5. Ordre : veut-il le Metadata Editor avant les playlists (il sert à tout) ?

## Vérification
- Chaque étape : `Tools/Build/build.sh` (3 OS), `swift test`, lancement par `Tools/Build/run-mac.sh` et contrôle visuel des sections.
- Perfs : `Tools/DbTest/run.sh <dossier musique> <scratch> --import-bench` avant/après.
- Au repos : vérifier l'absence de timers et de polling (Activity Monitor).
- Suivi : une carte du Project « iPod Pro Max » par étape, créée avant de commencer (règle d'AGENTS.md) ; la feuille de route finale est à discuter avec Julien avant de créer le prochain Project.
