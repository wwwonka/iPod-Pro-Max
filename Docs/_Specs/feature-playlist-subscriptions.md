# Abonnements à des playlists en ligne

Source : échanges avec Julien du 15 novembre 2026. Contrat des plug-ins : [[feature-plugins]]. Plug-ins utilisés : [[feature-plugin-spotify]], [[feature-plugin-soulseek]], [[feature-plugin-ytdlp]].

## Cadre

- **Objectif général** : dans la section Musique, je colle l'URL d'une de mes playlists Spotify. L'app télécharge automatiquement les morceaux qui me manquent, dans la qualité voulue (Soulseek d'abord, yt-dlp en dernier recours), les tague, les range dans ma bibliothèque et tient à jour une playlist locale, synchronisée avec l'iPod comme les autres.
- **Périmètre** : dix chantiers, découpés en sous-tâches numérotées de SUB-1 à SUB-18.
- **Architecture** : le moteur (`SubscriptionEngine`) est dans le cœur, pas dans un plug-in. Il ne connaît que les rôles `playlistSource`, `resolver` et `downloader`. Toute source fonctionne donc avec tout résolveur.
- **Plateformes** : macOS d'abord, en Swift portable (Foundation). Aucune API propre à l'OS dans le moteur ; les écrans passent par les trois contrôles natifs déjà en place (AppKit, GTK, WinUI). Raccourcis notés à la manière de macOS ; Ctrl remplace ⌘ et Alt remplace ⌥ sur Windows et Linux.
- **Langue** : les textes de l'interface sont en anglais, entre guillemets droits (`"Subscribe"`).
- **Performance** : aucun minuteur. Le réseau est la limite, pas le CPU. La progression est publiée en lots, environ toutes les 500 ms. Aucun accès disque par ligne ni par rendu.
- **Statut du contenu** : ce qui est marqué « À confirmer » est repris dans les Questions ouvertes.

## Vue d'ensemble

| Section | Sous-tâches |
| --- | --- |
| 1. Créer un abonnement | SUB-1, SUB-2 |
| 2. La playlist d'abonnement dans la sidebar | SUB-3, SUB-4 |
| 3. Vue de la playlist d'abonnement | SUB-5, SUB-6 |
| 4. Synchronisation | SUB-7, SUB-8, SUB-9 |
| 5. Morceaux déjà présents | SUB-10 |
| 6. Choix de la source et qualité | SUB-11, SUB-12, SUB-13 |
| 7. Emplacement des fichiers et tags | SUB-14, SUB-15 |
| 8. Se désabonner | SUB-16 |
| 9. Partage | SUB-17 |
| 10. Validation de bout en bout | SUB-18 |

Ce qui se passe pour chaque abonnement :

```
URL ─► source choisie par urlPatterns ─► source/fetch ─► Playlist + [TrackRef]
    ─► pour chaque morceau :
         déjà dans la bibliothèque ? ─► oui : lié
         sinon, résolveurs dans l'ordre des Préférences :
             resolver/search ─► note du cœur ─► meilleur candidat au-dessus du seuil ?
                 non ─► résolveur suivant
             downloader/download ─► échec ─► candidat suivant (3 au plus par résolveur)
         vérification ─► tags du TrackRef ─► pochette ─► paroles ─► rangement ─► bibliothèque
    ─► playlist locale dans l'ordre de la source
```

---

## 1. Créer un abonnement

### Objectifs

S'abonner à une playlist en ligne en un geste : un raccourci, une URL collée, un clic.

### Sous-tâches

- **SUB-1** : ajouter le menu `"New Subscription…"` (⌥⌘N) et la fenêtre où l'on saisit l'URL.
- **SUB-2** : quand on colle une URL reconnue dans la fenêtre principale, ouvrir cette même fenêtre déjà remplie.

### Comportement utilisateur

- L'utilisateur appuie sur ⌥⌘N, ou choisit File → `"New Subscription…"`, ou clic droit sur l'en-tête Playlists de la sidebar → `"New Subscription…"`.
- Une fenêtre s'ouvre, le curseur est déjà dans le champ URL. Il colle l'URL de sa playlist Spotify. Le logo Spotify apparaît dans le champ.
- Il appuie sur Retour ou clique `"Subscribe"`. Un indicateur tourne quelques secondes, la fenêtre se ferme, et la nouvelle playlist apparaît dans la sidebar, déjà sélectionnée. Les morceaux qu'il a déjà s'affichent normalement ; les autres sont grisés et se remplissent au fur et à mesure des téléchargements.
- S'il colle une URL Spotify (⌘V) alors que la fenêtre principale a le focus et qu'aucun champ texte n'est actif, la fenêtre `"New Subscription"` s'ouvre avec l'URL déjà remplie.

### Règles d'interaction

- **Menu** : `"New Subscription…"` se place dans le menu File, juste sous `"New Playlist"` (⌘N) et `"New Folder"` (⇧⌘N), dans `AppMenuMac.swift`. Il est actif quand la section Musique est affichée ; ailleurs, il ouvre la section Musique d'abord.
- **Fenêtre** : une feuille attachée à la fenêtre principale sur macOS, un dialogue modal sur GTK et WinUI. Elle contient :
  - le titre `"New Subscription"` ;
  - le champ URL avec le texte indicatif `"Paste a playlist link from Spotify, YouTube…"` (la liste des services vient des plug-ins `playlistSource` activés) ;
  - une zone de message sous le champ ;
  - les boutons `"Cancel"` (Échap) et `"Subscribe"` (Retour, bouton par défaut).
- **Détection du service** : à chaque modification du champ, l'URL nettoyée des espaces est testée contre les `urlPatterns` des plug-ins `playlistSource`, sans lancer de processus. Si un plug-in correspond, son badge s'affiche à gauche dans le champ et `"Subscribe"` devient actif.
- **Source désactivée** : si le plug-in qui correspond est désactivé, ou si son consentement n'a pas encore été donné, `"Subscribe"` déclenche d'abord l'alerte de consentement ([[feature-plugins]], section 6), puis continue si l'utilisateur accepte.
- **Premier abonnement** : si aucun plug-in `resolver` n'est activé, une alerte propose de les activer : `"To download songs, enable a download source."`, boutons `"Enable Soulseek and yt-dlp…"` et `"Not Now"`. Les consentements sont demandés l'un après l'autre. Avec `"Not Now"`, l'abonnement est créé quand même : les morceaux manquants restent à l'état « Waiting for a download source ».
- **Validation** : `"Subscribe"` appelle `source/fetch`. Pendant l'appel, le champ et `"Subscribe"` sont désactivés, un indicateur d'activité tourne à droite du champ, et `"Cancel"` reste actif (il annule la requête).
- **Succès** : l'abonnement est enregistré (section 4), la playlist est créée, la fenêtre se ferme, la playlist est sélectionnée dans la sidebar, puis la première synchro démarre en arrière-plan.
- **Doublon** : si la même source et le même `sourceID` sont déjà suivis, rien n'est créé. La fenêtre se ferme et la playlist existante est sélectionnée.
- **Collage dans la fenêtre principale (SUB-2)** : seulement si aucun champ texte n'a le focus et que le texte du presse-papiers correspond aux `urlPatterns` d'une source. Sinon, ⌘V garde son comportement habituel.

### États visuels

- **Vide** : champ vide avec le texte indicatif, `"Subscribe"` désactivé, zone de message vide.
- **URL reconnue** : badge du service dans le champ, `"Subscribe"` actif.
- **URL non reconnue** : pas de badge, `"Subscribe"` désactivé, message gris `"This link isn't supported."` Le message n'apparaît qu'une fois le texte rempli et ressemblant à une URL (il contient `://` ou un point), jamais pendant la frappe d'un mot.
- **Lecture en cours** : champ désactivé, indicateur d'activité, `"Cancel"` actif.
- **Erreur** : message rouge sous le champ, champ de nouveau modifiable, `"Subscribe"` actif pour réessayer. Messages selon l'erreur :
  - `notFound` : `"This playlist doesn't exist or is private."`
  - `network` : `"Can't reach Spotify. Check your connection."`
  - `apiChanged` : `"Spotify changed how it works. Update the Spotify plug-in."`
  - `rateLimited` : `"Spotify is limiting requests. Try again in a minute."`
  - autre : le message du plug-in.

### Edge cases

- URL avec des espaces autour, des paramètres de suivi (`?si=…`) ou un préfixe de langue (`/intl-fr/`) : acceptée, la source se charge de la nettoyer.
- URL d'album plutôt que de playlist : acceptée si la source le permet (Spotify : oui). L'abonnement porte alors sur l'album.
- Playlist vide : l'abonnement est créé, la playlist est vide, et l'en-tête de la vue affiche `"0 songs"`.
- Hors ligne au moment de valider : erreur `network`, rien n'est créé.
- Plusieurs plug-ins correspondent à la même URL : on prend le premier par ordre alphabétique d'`id`, et un avertissement va dans le journal. Ce cas ne doit pas arriver avec les plug-ins fournis.
- La fenêtre est ouverte depuis une autre section que Musique : la section Musique s'affiche quand on valide.

---

## 2. La playlist d'abonnement dans la sidebar

### Objectifs

Qu'une playlist d'abonnement se range et se manipule comme une playlist ordinaire, tout en montrant d'un coup d'œil de quel service elle vient et si elle est en cours de mise à jour.

### Sous-tâches

- **SUB-3** : ajouter la ligne de playlist d'abonnement dans la sidebar (place, nom, indicateur d'activité, menu contextuel).
- **SUB-4** : créer l'icône composite : l'icône de playlist dont la note de musique est remplacée par le badge du service.

### Comportement utilisateur

- La nouvelle playlist apparaît dans le groupe Playlists, à la position d'une nouvelle playlist (comme ⌘N), avec le nom qu'elle a sur Spotify.
- Son icône ressemble à celle des autres playlists, mais le logo Spotify remplace la note de musique.
- Pendant une mise à jour, un petit indicateur d'activité tourne à droite de la ligne.
- L'utilisateur peut la glisser pour la réordonner, la ranger dans un dossier, la synchroniser avec l'iPod et la lire comme n'importe quelle playlist.
- Le clic droit propose en plus `"Refresh"`, `"Open in Spotify"` (le nom change avec le service) et `"Unsubscribe…"`.

### Règles d'interaction

- **Modèle** : une `LibraryPlaylist` avec un champ `subscriptionID: UUID?` (facultatif à la lecture, pour que les anciens fichiers restent lisibles).
- **Import sans copier d'URL** : `"Import Playlists from Account…"` (menu File, `AppMenuMac.swift`, menu `+` des playlists dans `SidebarMac.swift`, et bouton `"Browse My Playlists…"` dans `NewSubscriptionSheet`) ouvre `ImportRemotePlaylistsSheet`. Elle détecte automatiquement les plug-ins `PlaylistSource` dotés d'un compte, interroge `source/listUserPlaylists` (avec rafraîchissement WebView transparent si besoin), filtre les playlists du compte, marque celles déjà abonnées (`Already in library`), et permet la sélection multiple et l'import groupé.
- **Création d'une playlist distante** : les entrées `"New Spotify Playlist…"` et `"New YouTube Music Playlist…"` (menu File, `AppMenuMac.swift`, et menu `+` des playlists dans `SidebarMac.swift`) ouvrent `NewRemotePlaylistSheet`, qui crée la playlist sur le service (`source/createPlaylist`) et l'abonne immédiatement dans l'application.
- **Renommage** : le renommage en ligne dans la sidebar ou par menu contextuel est actif sur les playlists abonnées ; pour une source conforme à `PlaylistEditable` (Spotify ou YouTube Music avec session Web), `SubscriptionController.renamePlaylist` pousse le nouveau nom sur la source (`source/rename`), applique un maintien optimiste de 10 s contre le lag de réplication, puis rafraîchit la playlist.
- **Édition et réordonnancement des morceaux** : le glisser-déposer de morceaux locaux sur une playlist abonnée dans `SidebarMac` recherche et ajoute ces titres à distance (`source/addTracks`), le réordonnancement interne appelle `source/reorder`, et `"Remove from Playlist"` dans `TrackTable` retire l'occurrence exacte (`subscriptionKey`) en local et à distance (`source/removeTracks`). Toute mutation réussie déclenche `refreshAfterMutation` pour mettre à jour l'état et afficher la date `"Updated just now"`.
- **Icône (SUB-4 et adaptation par service)** :
  - pour Spotify et YouTube Music, une icône dédiée dessinée dans `Symbols.swift` (`subscriptionSidebarSymbol`) affiche un anneau de contour vide reprenant exactement la circonférence et l'épaisseur du symbole `"clock"` (« Recently Added »), avec le tracé vide centré propre à chaque service (trois vagues Spotify ou anneau + triangle lecture YouTube Music) ;
  - pour les autres services (`music.note.list` décliné par service), l'icône composite associe `playlist-lines` et le badge du manifeste en image modèle monochrome mise en cache ;
  - **repli** : si le badge est absent ou illisible, `music.note.list` + petit symbole `icloud`.
- **Indicateur d'activité** : ref-compté (`beginActivity` / `endActivity` dans `SubscriptionController`) afin de couvrir proprement mutations et synchronisations simultanées sur la même playlist sans disparition prématurée.

### États visuels

- **Normal** : icône composite et nom.
- **Synchro en cours** : petit indicateur d'activité à droite (taille d'un compteur de la sidebar).
- **Erreur de la dernière synchro** (source introuvable, plug-in manquant) : petit triangle d'alerte à droite, avec une info-bulle qui donne le message.
- **Survol, sélection, glisser** : identiques à une playlist ordinaire.

### Edge cases

- Plug-in source désinstallé : la playlist reste, avec l'icône de repli et le triangle d'alerte (`"Plug-in 'Spotify' is missing"`).
- Deux abonnements avec le même nom : affichés tous les deux, sans renommage automatique.
- Un abonnement placé dans un dossier : il garde sa place lors des synchros.
- Sidebar sur Windows et Linux : le badge passe par la même police de symboles locale que les autres icônes personnalisées. Vérifier qu'aucun glyphe ne manque.

---

## 3. Vue de la playlist d'abonnement

### Objectifs

En ouvrant la playlist, voir où en est l'abonnement (mise à jour, morceaux disponibles, en cours, introuvables) et pouvoir agir sur chaque morceau.

### Sous-tâches

- **SUB-5** : ajouter l'en-tête de la vue (source, dernière mise à jour, résumé, `"Refresh"`).
- **SUB-6** : ajouter la colonne d'état par morceau et les actions sur un morceau introuvable ou en échec.

### Comportement utilisateur

- En haut de la vue, sous le titre de la playlist, il lit par exemple : `"Spotify · Updated 5 minutes ago · 54 of 60 songs available"`, avec un bouton `"Refresh"`.
- Pendant une synchro, le résumé devient `"Downloading 3 of 6…"` et `"Refresh"` est remplacé par `"Stop"`.
- Dans la liste, les morceaux disponibles s'affichent normalement. Les autres sont grisés, avec une icône d'état dans la colonne la plus à gauche.
- Pour un morceau introuvable, il peut faire un clic droit → `"Try Again"`.
- Il peut lire les morceaux disponibles ; les morceaux grisés sont sautés à la lecture.

### Règles d'interaction

- **En-tête (`SubscriptionHeaderView`)** :
  - pochette cliquable (avec survol `"Click to change cover (1:1 JPEG, min 300×300 px)"`) ouvrant le sélecteur d'image (`NSOpenPanel`) pour téléverser une nouvelle pochette carrée via `source/setArtwork` (sans bouton texte séparé) ;
  - cache mémoire `verifiedArtworkKeys` dans `SubscriptionController.artworkURL(for:)` évitant les vérifications `fileExists` répétées à chaque rendu ;
  - badge du service + `"<Service> · Updated <date relative> · <n> of <total> songs available"` ;
  - bouton icône SF Symbol `arrow.clockwise` (info-bulle `"Refresh Playlist"`) lançant une synchro de cette playlist (section 4) ;
  - pendant une synchro ou mutation, indicateur d'activité + bouton `"Stop"` annulant les recherches et téléchargements de cette playlist (les fichiers déjà terminés sont gardés).
- **Colonne d'état** : étroite, sans titre, toujours visible dans une playlist d'abonnement et absente ailleurs. États :

| État | Icône | Info-bulle | Ligne |
| --- | --- | --- | --- |
| Disponible | aucune | — | normale |
| Disponible depuis YouTube | petit `play.rectangle` | `"Downloaded from YouTube (lower quality)"` | normale |
| En attente | `clock` | `"Waiting"` | grisée |
| Recherche | indicateur d'activité | `"Searching Soulseek…"` | grisée |
| Téléchargement | anneau de progression (0 à 100 %) | `"Downloading from Soulseek – 42%"` | grisée |
| Introuvable | `questionmark.circle` | `"Not found. Will try again tomorrow."` | grisée |
| Échec | `exclamationmark.triangle` | la raison | grisée |
| Pas de source de téléchargement | `arrow.down.circle.dotted` | `"Enable a download source in Settings › Plug-ins"` | grisée |

- **Menu contextuel** d'un morceau qui n'est pas disponible : `"Try Again"` (relance tout de suite, en ignorant le délai de 24 h), `"Show Search Results…"` (v2, voir Hors périmètre), `"Copy Song Info"`.
- **Lecture** : les morceaux qui ne sont pas disponibles ne peuvent pas être lus. Ils sont sautés dans la file, et un double-clic dessus ne fait rien.
- **Glisser vers un iPod** : seuls les morceaux disponibles partent.
- **Mises à jour de l'affichage** : regroupées toutes les 500 ms. La position de défilement et la sélection ne bougent pas quand un morceau change d'état.

### États visuels

- **Synchro en cours** : résumé `"Downloading <x> of <y>…"`, bouton `"Stop"`.
- **À jour** : résumé normal, bouton `"Refresh"`.
- **Hors ligne** : `"Offline · Updated <date>"`, bouton `"Refresh"` actif.
- **Erreur de source** : bandeau jaune sous l'en-tête avec le message (par exemple `"Spotify changed how it works. Update the Spotify plug-in."`), bouton `"Refresh"`.
- **Tout disponible** : `"60 songs"`, sans « of ».

### Edge cases

- Morceau disponible dont le fichier disparaît plus tard (disque débranché) : comme dans le reste de la bibliothèque, il disparaît de la liste. Il n'est pas retéléchargé tant que le dossier source reste configuré mais inaccessible.
- Playlist de plus de 1 000 morceaux : la table virtualisée existante suffit, et le résumé est calculé en mémoire.
- `"Stop"` pendant un téléchargement à 99 % : le fichier partiel est supprimé, et le morceau repasse « En attente ».

---

## 4. Synchronisation

### Objectifs

Garder la playlist locale fidèle à la playlist en ligne : nouveaux morceaux, morceaux retirés, nouveau nom, nouvel ordre. Le faire sans aucun travail au repos, et sans perdre l'état d'un hôte à l'autre.

### Sous-tâches

- **SUB-7** : créer `subscriptions.json` (modèle, lecture et écriture sûres, sur l'iPod).
- **SUB-8** : brancher les déclencheurs (ajout, lancement de l'app, ouverture de la playlist, `"Refresh"`), sans minuteur.
- **SUB-9** : appliquer les changements de la source à la playlist locale.

### Comportement utilisateur

- À chaque lancement de l'app, ses abonnements se mettent à jour en arrière-plan.
- En ouvrant une playlist d'abonnement, elle se met à jour si la dernière mise à jour date de plus de 15 minutes.
- Un morceau ajouté sur Spotify apparaît dans la playlist locale. Un morceau retiré de Spotify disparaît de la playlist, mais reste dans la bibliothèque.

### Règles d'interaction

- **Stockage** : `Persistent Data/subscriptions.json`, sur l'iPod (ADR-006). Une entrée par abonnement :
  - `id`, `source`, `sourceID`, `url`, `title` ;
  - `playlistID` (la `LibraryPlaylist`), `revision` (la dernière vue), `lastSync` ;
  - `tracks` : liste ordonnée de `{sourceID, ref: TrackRef, state, trackKey?, lastTry?, failure?}`.
  - `trackKey` est l'empreinte du fichier dans `manifest.json`. C'est elle qui retrouve le morceau sur n'importe quel hôte.
- **Déclencheurs** :
  1. création de l'abonnement ;
  2. lancement de l'app : une passe sur tous les abonnements, en QoS `.utility`, 10 s après le chargement de la bibliothèque, l'un après l'autre ;
  3. ouverture de la playlist, si `lastSync` date de plus de 15 minutes ;
  4. `"Refresh"`.

  **Aucun minuteur, aucune vérification à intervalle régulier.**
- **Révision inchangée** : si `source/fetch` renvoie la même `revision`, on s'arrête là. On ne fait que retenter les morceaux en attente, introuvables (après 24 h) ou en échec.
- **Changements** :
  - nouveau morceau : ajouté à `tracks` en « En attente » ;
  - morceau retiré : retiré de `tracks` et de la playlist locale ; **le fichier reste dans la bibliothèque** ;
  - ordre modifié : la playlist locale suit l'ordre de la source ;
  - titre modifié : la playlist locale est renommée.
- **Une seule synchro à la fois par abonnement.** `"Refresh"` pendant une synchro ne fait rien. Plusieurs abonnements peuvent avancer en même temps, dans les limites de la section 6.
- **Écriture** : `subscriptions.json` est écrit par lots, à la fin d'une synchro, toutes les 20 pistes terminées, et à la fermeture de l'app. Jamais à chaque piste, pour ne pas réveiller le disque de l'iPod.

### États visuels

- Voir les sections 2 et 3.

### Edge cases

- Playlist supprimée ou rendue privée sur Spotify : la synchro échoue avec `notFound`. La playlist locale reste telle quelle, avec le bandeau d'erreur. Rien n'est supprimé.
- App fermée pendant une synchro : les téléchargements en cours sont abandonnés et les fichiers partiels supprimés au prochain lancement (section 7). Les morceaux concernés repartent de « En attente ».
- Un même morceau dans deux abonnements : un seul téléchargement, partagé par les deux playlists.
- `subscriptions.json` illisible : on reprend `.bak`. Si lui aussi est illisible, les abonnements sont perdus, mais les playlists et les fichiers restent, comme des playlists ordinaires. Un message s'affiche une fois.
- iPod utilisé sur un autre hôte où le dossier de téléchargement n'existe pas : les morceaux liés dont le fichier est absent sur cet hôte s'affichent comme absents de la bibliothèque (règle existante). Ils ne sont **pas** retéléchargés automatiquement. À confirmer.

---

## 5. Morceaux déjà présents

### Objectifs

Ne jamais retélécharger un morceau qu'on a déjà, même s'il a été importé autrement.

### Sous-tâches

- **SUB-10** : faire correspondre un `TrackRef` avec la bibliothèque, à l'aide d'un index en mémoire construit une fois par synchro.

### Comportement utilisateur

- Les morceaux qu'il possède déjà s'affichent tout de suite comme disponibles dans la nouvelle playlist, sans téléchargement.

### Règles d'interaction

- Un `TrackRef` correspond à une piste de la bibliothèque si l'une de ces règles s'applique, dans l'ordre :
  1. même `source` et même `sourceID` dans `subscriptions.json` (un morceau déjà téléchargé par un abonnement) ;
  2. même ISRC, si les deux en ont un ;
  3. même artiste principal et même titre après normalisation, **et** durée à ±3 s. Si l'une des deux durées manque, on exige aussi le même album normalisé.
- **Normalisation** : minuscules ; accents retirés ; `&` → `and` ; on retire les parenthèses et crochets qui contiennent `feat.`, `ft.`, `with`, `remaster`, `remastered`, `radio edit`, `single version`, `album version` ; on retire tout ce qui suit ` - ` quand c'est `Remastered …` ou `<année> Remaster` ; ponctuation retirée ; espaces réduits.
- Si plusieurs pistes correspondent, on préfère, dans l'ordre : celle du dossier de téléchargement, puis la meilleure qualité (même ordre que la politique de la section 6), puis la plus récente.
- L'index est construit en mémoire à partir de la bibliothèque déjà chargée, une fois par synchro. Aucun accès disque.

### États visuels

- Aucun en propre : les morceaux trouvés sont « Disponible ».

### Edge cases

- Une version live de la bibliothèque a le même titre que la version studio demandée : la règle 3 l'écarte par la durée, dans la plupart des cas.
- Les morceaux du même titre sur des albums différents (single et album) : n'importe lequel convient, puisque la durée correspond.
- La bibliothèque change pendant la synchro (scan en cours) : l'index n'est pas reconstruit. Les nouveaux morceaux seront vus à la synchro suivante.

---

## 6. Choix de la source et qualité

### Objectifs

Pour chaque morceau manquant, trouver le meilleur fichier disponible selon la politique de qualité de l'utilisateur, en essayant les sources dans l'ordre choisi. Et **ne jamais prendre un mauvais morceau** (remix, mashup, version live) quand on demandait l'original.

### Sous-tâches

- **SUB-11** : écrire `CandidateScorer`, la fonction pure qui rejette et classe les candidats selon la politique de qualité.
- **SUB-12** : écrire l'enchaînement des résolveurs dans `SubscriptionEngine` (actor) : ordre, repli, essais, annulation, limites de concurrence.
- **SUB-13** : ajouter la carte `"Downloads"` des Préférences (politique de qualité).

### Comportement utilisateur

- Dans Préférences → Plug-ins → `"Downloads"`, l'utilisateur ordonne les formats qu'il préfère et choisit un débit minimum.
- Dans `"Download Sources"`, il ordonne les sources (Soulseek, puis yt-dlp par défaut).
- Il n'a rien à faire pendant les téléchargements. Un morceau introuvable partout est marqué introuvable.

### Règles d'interaction

- **Politique de qualité** (carte `"Downloads"`) :
  - `"Preferred formats"` (`orderedList`) : par défaut FLAC, ALAC, MP3 320, AAC 256 et plus, MP3 V0, puis `"Any other format"` ;
  - `"Minimum bitrate"` (`int`, kb/s) : 192 par défaut (valeur de l'ancien projet), ne s'applique pas aux formats sans perte ;
  - `"Accept YouTube when nothing else is found"` (`bool`, vrai par défaut) : n'apparaît que si yt-dlp est activé.
- L'iPod ne lit pas le FLAC : la conversion se fait déjà à la sync, dans MediaKit. On garde le fichier sans perte dans la bibliothèque.
- **Rejets** (éliminatoires), contrôlés sur le titre, le nom de fichier et le chemin du candidat :
  1. durée connue qui s'écarte de plus de 3 s de celle du `TrackRef`. La tolérance passe à 5 s pour yt-dlp (vidéos avec intro ou fin). Si la durée du candidat est inconnue, la règle ne s'applique pas, mais le candidat perd une place au classement ;
  2. un de ces mots présent dans le candidat **mais absent du titre et de l'album de référence** : `remix`, `mix`, `mashup`, `edit`, `rework`, `bootleg`, `clean`, `instrumental`, `karaoke`, `acapella`, `a cappella`, `cover`, `live`, `sped up`, `slowed`, `reverb`, `nightcore`, `8d`, `bpm`, `djpool`, `dj pool`, `tribute`, `ringtone` ;
  3. un mot significatif du titre de référence absent du candidat (mots de 3 lettres et plus, après normalisation, sans `the` ni `and`) ;
  4. qualité sous le minimum de la politique ;
  5. format absent de la liste des formats préférés, si `"Any other format"` en a été retiré.

  Ces règles corrigent l'ancien projet, où la durée était fixée en dur à 180 s : `sync.log` y montre un mashup de DJ pool choisi pour « Choosin' Texas ».
- **Classement** des candidats restants :
  1. rang du format dans la politique ;
  2. écart avec le débit visé (le débit le plus élevé du format) ;
  3. disponibilité : créneau libre, puis file courte, puis vitesse annoncée ;
  4. album présent dans le chemin ou les tags ;
  5. `hint` du plug-in.
- **Enchaînement** :
  - les résolveurs sont essayés dans l'ordre de `"Download Sources"`. On passe au suivant quand un résolveur ne fournit aucun candidat accepté, ou que ses 3 meilleurs candidats ont tous échoué au téléchargement ;
  - yt-dlp n'est essayé que si `"Accept YouTube…"` est vrai ;
  - si tout échoue, le morceau passe à « Introuvable » (aucun candidat accepté) ou « Échec » (des candidats, mais tous en échec), avec `lastTry`.
- **Nouvelle tentative** : un morceau introuvable ou en échec est retenté à la synchro suivante, au plus une fois par 24 h. `"Try Again"` ignore ce délai.
- **Concurrence** (tous abonnements confondus) :
  - au plus 3 recherches en même temps, parce que le serveur Soulseek peut pénaliser les recherches trop rapprochées ;
  - au plus 4 téléchargements en même temps, dont au plus 2 avec yt-dlp ;
  - l'étiquetage, la vérification et la pochette tournent dans une fenêtre glissante de `activeProcessorCount` tâches, en QoS `.utility`.

### États visuels

- Carte `"Downloads"` : la liste des formats est réordonnable par glisser-déposer, avec une poignée à droite de chaque ligne. Le champ du débit minimum a l'unité `kbps`.

### Edge cases

- Titre de référence qui contient lui-même un mot de la liste (« Mix Tape », « Live Forever ») : la règle 2 ne s'applique qu'aux mots absents de la référence. Le morceau reste trouvable.
- Morceau officiellement remixé (« Song (Artist Remix) ») : `remix` figure dans la référence, donc les remixes sont acceptés.
- Tous les candidats sont en MP3 128 : rejetés par le minimum. Le morceau passe à yt-dlp, s'il est accepté, sinon il est introuvable.
- Aucun résolveur activé : les morceaux restent à l'état « Pas de source de téléchargement ».
- Le candidat téléchargé ne correspond pas à ce qu'il annonçait (durée réelle différente de plus de 3 s, fichier illisible) : il est supprimé et traité comme un échec de téléchargement. On passe au candidat suivant.

---

## 7. Emplacement des fichiers et tags

### Objectifs

Ranger les morceaux téléchargés à un endroit prévisible, avec des tags propres tirés de la source, pour qu'ils apparaissent tout de suite dans la bibliothèque et se synchronisent avec l'iPod.

### Sous-tâches

- **SUB-14** : choisir le dossier de destination (Téléchargements de l'hôte, réglage par hôte, ajout automatique comme source Musique, repli sur l'iPod), gérer les fichiers partiels et vérifier les fichiers.
- **SUB-15** : taguer à partir du `TrackRef`, avec la pochette téléchargée une fois par album et les paroles de LRCLIB.

### Comportement utilisateur

- Les morceaux apparaissent dans le dossier Téléchargements de l'ordinateur, sous `iPod Pro Max/<Artiste>/<Album>/`.
- Ils apparaissent dans la bibliothèque avec le bon titre, le bon album, la bonne pochette et, si elles existent, leurs paroles.
- L'utilisateur peut choisir un autre dossier dans les Préférences, pour cet ordinateur.

### Règles d'interaction

- **Dossier par défaut** (décidé le 2026-11-15) : `<Téléchargements>/iPod Pro Max/`. Le dossier Téléchargements est trouvé avec `FileManager.url(for: .downloadsDirectory, …)` sur macOS et Windows, et avec `xdg-user-dir DOWNLOAD` sur Linux (repli : `~/Downloads`).
- **Réglage** : `"Download folder"` (`folder`) dans la carte `"Downloads"`, propre à chaque hôte (`known_hosts.json`), avec `"Choose…"` et `"Reset"`.
- **Source Musique automatique** : à la première écriture, le dossier de téléchargement est ajouté aux dossiers Musique de l'hôte dans `known_hosts.json`. Il apparaît dans Préférences → General comme les autres. Si l'utilisateur l'en retire, il n'est pas rajouté tant que le dossier de téléchargement ne change pas. À confirmer.
- **Repli** : si le dossier est introuvable ou en lecture seule, on écrit sur l'iPod, dans `iPod Pro Max/Downloads/`. Ce dossier est une source de bibliothèque visible sur tous les hôtes. Un message s'affiche une fois par session : `"Couldn't write to <dossier>. Songs are saved on the iPod instead."`
- Ce sont des médias que l'utilisateur a demandés : ils ne contredisent pas ADR-006, qui interdit les fichiers *de l'application* sur l'hôte.
- **Nom de fichier** : `<Artiste de l'album>/<Album>/<NN> <Titre>.<ext>` (avec `<D>-<NN>` s'il y a plusieurs disques). Les caractères interdits sur FAT32, NTFS et ext4 (`\ / : * ? " < > |`) sont remplacés par `_` ; chaque segment est limité à 120 caractères. Si le nom existe déjà avec un autre contenu, on ajoute ` (2)`.
- **Fichiers partiels** : le téléchargement est écrit dans `paths.temp`, sous `<nom>.part`. Le fichier n'est déplacé dans le dossier de destination qu'après vérification : décodable par MediaKit, et durée réelle à ±3 s de la référence (±5 s pour yt-dlp). Au lancement de l'app, les `.part` orphelins sont supprimés.
- **Tags** (via `TagWriter` de MediaKit) : ils viennent **du `TrackRef`, qui fait foi**, et non du fichier téléchargé.
  - On écrit : titre, artistes (joints par `, `), album, artiste de l'album, numéros de piste et de disque, année, ISRC, et un commentaire `"Source: <service>"`.
  - On efface les tags existants du fichier, sauf les tags techniques (ReplayGain).
- **Pochette** : téléchargée une seule fois par album et par synchro, avec la même déduplication que l'import, réencodée en JPEG de 600 px au maximum, puis intégrée au fichier.
- **Paroles** : `LRCLIBProvider` (synchronisées si possible, sinon texte brut). Pas d'échec si rien n'est trouvé.

### États visuels

- Carte `"Downloads"` : `"Download folder"` affiche le chemin, ou `"Downloads › iPod Pro Max (default)"`.

### Edge cases

- Le dossier de téléchargement est dans un dossier Musique déjà configuré : on ne l'ajoute pas une seconde fois.
- Disque plein en cours de téléchargement : échec du morceau, `"Not enough disk space"`, et les téléchargements de cette synchro s'arrêtent.
- Fichier FLAC de plus de 4 Go sur l'iPod en FAT32 : impossible en pratique pour un morceau. On refuse si le fichier fait plus de 4 Go.
- Pochette introuvable (URL morte) : morceau tagué sans pochette, sans échec.
- Le format du fichier ne prend pas en charge un tag : on l'ignore pour ce fichier.

---

## 8. Se désabonner

### Objectifs

Arrêter de suivre une playlist en ligne, en choisissant clairement de garder ou non la playlist et les fichiers.

### Sous-tâches

- **SUB-16** : ajouter l'action `"Unsubscribe…"` et son alerte à trois choix.

### Comportement utilisateur

- Clic droit sur la playlist dans la sidebar → `"Unsubscribe…"`. On peut aussi sélectionner la playlist et appuyer sur ⌫ : la suppression d'une playlist d'abonnement passe par la même alerte.
- Une alerte demande s'il veut garder la playlist et les fichiers, ou tout retirer.

### Règles d'interaction

- Alerte native (NSAlert sur macOS, dialogue équivalent sur GTK et WinUI) :
  - titre : `"Unsubscribe from “<playlist>”?"` ;
  - texte : `"Songs will no longer be updated from <Service>."` ;
  - boutons :
    1. `"Keep Playlist and Files"` (par défaut) : l'abonnement est supprimé de `subscriptions.json`, et la playlist devient une playlist ordinaire, avec l'icône normale, renommable et modifiable ;
    2. `"Remove Everything"` (destructif, en rouge sur macOS) : la playlist est supprimée. Les fichiers **téléchargés par cet abonnement** vont à la corbeille, **sauf** s'ils sont aussi dans une autre playlist ou un autre abonnement. Les morceaux qui étaient dans la bibliothèque avant l'abonnement ne sont jamais touchés. Les pistes disparaissent de l'iPod à la sync suivante ;
    3. `"Cancel"` (Échap).
- Une synchro en cours de cet abonnement est annulée avant l'action.
- Corbeille : `FileManager.trashItem` sur macOS et Windows, et le standard freedesktop sur Linux. Si la corbeille n'est pas disponible (fichiers sur l'iPod en FAT32), les fichiers sont supprimés définitivement, après une seconde alerte : `"These files can't be moved to the Trash. Delete them permanently?"`

### États visuels

- Alerte : sur macOS, `"Remove Everything"` avec le style destructif.

### Edge cases

- Fichiers déjà déplacés ou supprimés à la main : ignorés sans erreur.
- `"Remove Everything"` alors que des morceaux de cet abonnement sont dans la file de lecture : ils en sont retirés, et la lecture passe au morceau suivant si le morceau en cours est concerné.
- Annuler (⌘Z) n'est pas prévu.

---

## 9. Partage

### Objectifs

Partager de la musique sur Soulseek par défaut, pour être un bon membre du réseau et ne pas être refusé par les utilisateurs qui bloquent ceux qui ne partagent rien. On partage les dossiers de l'hôte, et l'iPod seulement en dernier recours.

### Sous-tâches

- **SUB-17** : construire l'index de partage et l'envoyer au plug-in `share` (`share/setIndex`).

### Comportement utilisateur

- Sans rien faire, l'utilisateur partage ses dossiers Musique, y compris le dossier de téléchargement. Sur un ordinateur sans dossier Musique, il partage la musique de l'iPod.
- Il peut couper le partage dans les réglages du plug-in Soulseek.

### Règles d'interaction

- **Source de l'index** (décidé le 2026-11-15) :
  1. **par défaut**, les dossiers Musique de l'hôte (`known_hosts.json`), dossier de téléchargement compris. Chemin virtuel : `<nom du dossier>\<chemin relatif>` ;
  2. **en dernier recours**, si l'hôte n'a aucun dossier Musique accessible, la musique de l'iPod. L'index est construit depuis l'iTunesDB, avec des chemins virtuels lisibles : `iPod\<Artiste>\<Album>\<NN> <Titre>.<ext>` → `iPod_Control/Music/Fxx/XXXX.ext`.
- **Envois simultanés** : **2** quand on partage les dossiers de l'hôte, **1** quand on partage l'iPod.
- **Annonce honnête** : on annonce (`SharedFoldersFiles`) exactement le nombre de dossiers et de fichiers de l'index, ni plus ni moins. Le serveur ne bloque personne selon ses partages, mais certains clients (Nicotine+, slskd) refusent d'envoyer à ceux qui partagent peu, et un pair qui trouve notre partage vide ou différent peut nous bannir.
- L'index est construit à partir de la bibliothèque déjà en mémoire, sans nouveau scan. Seuls les fichiers audio sont inclus.
- Il est renvoyé quand les dossiers Musique ou la bibliothèque changent, au plus une fois toutes les 30 s, regroupé.
- Le partage ne fonctionne que pendant que l'app est ouverte.

### États visuels

- Dans la carte Soulseek : `"Sharing 1,234 files in 56 folders"`, ou `"Sharing your iPod: 812 files"`, ou `"Not sharing"`.

### Edge cases

- Bibliothèque vide sur l'hôte et sur l'iPod : on annonce 0 fichier. Certains pairs refuseront alors les téléchargements, ce qui est indiqué dans le journal du plug-in.
- Un dossier Musique devient inaccessible : ses fichiers sortent de l'index au prochain envoi de l'index.
- Les fichiers vidéo, podcasts et livres audio ne sont jamais partagés en v1.

---

## 10. Validation de bout en bout

### Objectifs

Prouver que tout fonctionne sur une vraie playlist, et mesurer le taux de réussite.

### Sous-tâches

- **SUB-18** : abonnement à une vraie playlist Spotify publique de 20 à 60 morceaux sur `Build/` (iPod simulé), avec synchro vers l'iPod simulé.

### Comportement utilisateur

- Sans objet.

### Règles d'interaction

- Mesures notées dans `Docs/` :
  - durée totale ;
  - nombre de morceaux trouvés par Soulseek, par yt-dlp, et introuvables ;
  - **morceaux corrects**, vérifiés à l'écoute ou par la durée et le titre : objectif 100 % des morceaux trouvés ;
  - formats obtenus.
- Vérifier que relancer l'app ne retélécharge rien et que la deuxième synchro (révision inchangée) dure moins de 2 s.

### États visuels

- Sans objet.

### Edge cases

- À refaire après tout changement de `CandidateScorer`.

---

## Hors périmètre

- **Choix manuel d'un candidat** (`"Show Search Results…"` : liste des candidats avec format, débit, pair, pour en choisir un). Prévu en v2.
- Mise à jour automatique en arrière-plan quand l'app est fermée, ou à intervalle régulier.
- Abonnements à des artistes ou à des podcasts.
- Retéléchargement automatique sur un hôte où les fichiers sont absents.

## Questions ouvertes

1. ~~Faut-il interdire le renommage manuel d'une playlist d'abonnement ?~~ **Tranché (2026-11-20)** : le renommage est actif et synchronisé sur Spotify pour les playlists possédées (`source/rename`), avec maintien optimiste de 10 s côté UI.
2. Si l'utilisateur retire le dossier de téléchargement de ses dossiers Musique, faut-il le rajouter automatiquement plus tard ?
3. Sur un autre hôte où les fichiers téléchargés sont absents, faut-il retélécharger les morceaux, ou se contenter de ceux qui sont sur l'iPod ?
4. Le délai de 15 minutes avant une mise à jour à l'ouverture de la playlist vous convient-il ?
5. ~~Faut-il pouvoir réordonner ou compléter à la main une playlist d'abonnement ?~~ **Tranché (2026-11-20)** : réordonnancement (`source/reorder`), ajout par glisser-déposer (`source/addTracks`), retrait (`source/removeTracks`), changement de pochette par clic sur la pochette (`source/setArtwork`) et création distante (`source/createPlaylist`) sont activés pour les sources `PlaylistEditable`.
