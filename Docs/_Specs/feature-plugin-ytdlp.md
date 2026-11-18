# Plug-in yt-dlp : recherche et téléchargement de dernier recours

Contrat : [[feature-plugins]]. Utilisé par : [[feature-playlist-subscriptions]].

## Cadre

- **Rôles** : `resolver`, `downloader`. Dernier dans l'ordre des sources par défaut. `requiresConsent: "scraping"`.
- **Pourquoi en dernier** : la qualité plafonne (AAC ou Opus, environ 128 à 160 kb/s, toujours avec perte) et la correspondance est moins fiable. Les morceaux qui en viennent sont signalés dans la colonne d'état.
- **Référence** : `~/Desktop/Coding/Spotify-Soulseek-Downloader/src/youtube/ytdlp.ts`. Les commits `4365423` (repli quand Soulseek ne trouve rien) et `8e7ebac` (correction d'un débit sous la cible) donnent le contexte.
- **Plateformes** : le plug-in Swift lance le binaire yt-dlp officiel de chaque OS. Seuls les binaires embarqués changent d'un OS à l'autre.
- Sous-tâches : YTD-1 à YTD-8.

## Vue d'ensemble

| Section | Sous-tâches |
| --- | --- |
| 1. Binaires embarqués | YTD-1, YTD-2 |
| 2. Recherche | YTD-3 |
| 3. Téléchargement | YTD-4, YTD-5 |
| 4. Mise à jour de yt-dlp | YTD-6 |
| 5. Test et build | YTD-7, YTD-8 |

---

## 1. Binaires embarqués

### Objectifs

Que yt-dlp marche sans rien installer sur l'ordinateur, contrairement à l'ancien projet, qui le cherchait dans le `PATH`.

### Sous-tâches

- **YTD-1** : vérification préalable, avec un court rapport dans `Docs/`. Deux points :
  1. depuis fin 2025, yt-dlp aurait besoin d'un **runtime JavaScript externe** (Deno) pour une prise en charge complète de YouTube. Est-ce confirmé, et quelle taille faut-il ajouter par OS ?
  2. notre ffmpeg minimal (`Tools/FFmpeg/build.sh`) sait-il remuxer en m4a sans réencoder (muxer `ipod`/`mp4`, démuxeurs webm et matroska) et réencoder l'Opus en AAC ?
- **YTD-2** : script `Tools/Build/` qui télécharge les binaires officiels à une version figée et vérifie leur SHA256, sur le modèle de `Tools/FFmpeg/build.sh`. Il les place dans `vendor/` du plug-in.

### Comportement utilisateur

- Rien à installer. Après le consentement, le plug-in fonctionne.

### Règles d'interaction

- Binaires : `yt-dlp_macos` (universel) ; `yt-dlp.exe` (Windows x64, aussi utilisé sur ARM64 par émulation, sauf s'il existe un binaire officiel ARM64) ; `yt-dlp_linux` et `yt-dlp_linux_aarch64`.
- Si Deno est nécessaire (YTD-1), son binaire autonome par OS est embarqué dans `vendor/` et indiqué à yt-dlp par son option dédiée.
- **ffmpeg** : toujours `--ffmpeg-location <paths.ffmpeg>`, pour utiliser celui de l'app. Si YTD-1 montre qu'il manque des composants, on les ajoute à `Tools/FFmpeg/build.sh`, sans embarquer un second ffmpeg.

### États visuels

- Aucun.

### Edge cases

- Binaire absent ou non exécutable : carte en état « Error », `"yt-dlp is missing from the plug-in"`.
- macOS : le binaire de `vendor/` est signé ad hoc avec le reste du plug-in.

---

## 2. Recherche

### Objectifs

Trouver la version audio officielle du morceau sur YouTube, en évitant les clips avec intro, les versions live et les reprises.

### Sous-tâches

- **YTD-3** : rôle `resolver` : recherche YouTube Music en priorité, puis recherche YouTube générale, et conversion en `Candidate`.

### Comportement utilisateur

- Un morceau introuvable sur Soulseek affiche « Searching YouTube… », puis se télécharge.

### Règles d'interaction

- **Requête 1** : YouTube Music (`https://music.youtube.com/search?q=<artiste> <titre>`, onglet morceaux). Les résultats « - Topic » et les morceaux officiels portent l'audio de l'album.
- **Requête 2**, si la première ne donne aucun candidat accepté : `ytsearch5:"<artiste principal> - <titre>"`.
- Options : `--dump-json --flat-playlist --no-warnings`, sans téléchargement.
- **`Candidate`** :
  - `token` = URL de la vidéo ;
  - `displayName` = `<titre de la vidéo> — <chaîne>` ;
  - `durationMs` ;
  - `container` et `bitrateKbps` du meilleur format audio annoncé ;
  - `hint` : 0,9 pour une chaîne « - Topic » ou un résultat de YouTube Music, 0,6 pour une chaîne officielle de l'artiste (`<artiste>VEVO` ou la chaîne qui porte son nom), 0,3 sinon.
- Les rejets (live, cover, sped up…) et la durée (tolérance de 5 s) sont appliqués **par le cœur**.

### États visuels

- Aucun en propre.

### Edge cases

- Vidéo réservée aux adultes ou bloquée dans le pays : exclue des candidats.
- YouTube demande une vérification (« Sign in to confirm you're not a bot ») : erreur `rateLimited`, et le cœur arrête d'utiliser yt-dlp jusqu'à la fin de la synchro.

---

## 3. Téléchargement

### Objectifs

Récupérer l'audio dans un format que l'iPod lit, sans réencodage quand c'est possible.

### Sous-tâches

- **YTD-4** : rôle `downloader` : choix du format, sortie m4a, progression.
- **YTD-5** : annulation propre.

### Comportement utilisateur

- Le morceau affiche « Downloading from YouTube – 42% », puis devient disponible avec la mention « Downloaded from YouTube (lower quality) ».

### Règles d'interaction

- Format : `-f bestaudio[ext=m4a]/bestaudio`.
  - Si le flux est déjà en m4a (AAC) : remux sans réencodage.
  - Sinon (Opus) : réencodage en AAC 256 kb/s avec notre ffmpeg, parce que l'iPod ne lit pas l'Opus.
- Options : `--no-playlist --no-part --no-mtime --no-embed-thumbnail`. La pochette vient du `TrackRef`, jamais de la vignette YouTube.
- Sortie dans `destinationDir`, nom `<videoID>.m4a`. Le plug-in renvoie le chemin final.
- **Progression** : `--newline --progress-template "%(progress._percent_str)s"` lu sur stdout, puis transmis par `$/progress`, au plus 4 fois par seconde.
- **Annulation** : on termine le processus yt-dlp (SIGTERM, puis SIGKILL après 2 s ; `TerminateProcess` sur Windows) et on supprime le fichier partiel.
- Au plus 2 téléchargements yt-dlp en même temps, parce que ffmpeg utilise déjà plusieurs cœurs. C'est le cœur qui applique cette limite.

### États visuels

- Aucun en propre.

### Edge cases

- Erreur d'extraction (YouTube a changé) : échec `apiChanged`, avec le message `"yt-dlp needs an update"`. La carte propose `"Update yt-dlp"` (section 4).
- Vidéo de plus de 20 minutes pour un morceau de 3 minutes : déjà rejetée par la durée dans le cœur.

---

## 4. Mise à jour de yt-dlp

### Objectifs

YouTube casse souvent yt-dlp. L'utilisateur doit pouvoir le mettre à jour en un clic, sans attendre une nouvelle version de l'app, et sans que l'app vérifie quoi que ce soit en arrière-plan.

### Sous-tâches

- **YTD-6** : ajouter l'action `"Update yt-dlp"` (réglage de type `action`).

### Comportement utilisateur

- Dans la carte yt-dlp, l'utilisateur voit `"yt-dlp 2026.10.22"` et un bouton `"Update yt-dlp"`.
- Il clique : le bouton affiche un indicateur, puis `"Updated to 2026.11.10"` ou `"Already up to date"`.
- Après un échec d'extraction, la carte affiche en plus `"yt-dlp needs an update"`.

### Règles d'interaction

- L'action lance `yt-dlp -U` sur le binaire de `vendor/` de l'OS courant.
- Aucune vérification automatique ni périodique. La mise à jour n'est proposée qu'après une erreur d'extraction.
- La version est lue avec `yt-dlp --version` au moment où la carte s'ouvre, seulement si le plug-in tourne déjà. Sinon, on affiche la dernière version connue, enregistrée dans `settings.json`.

### États visuels

- **Au repos** : version et bouton.
- **En cours** : indicateur, bouton désactivé.
- **Résultat** : message pendant 5 s, puis retour au repos.
- **Échec** : message rouge (`"Update failed: <raison>"`).

### Edge cases

- iPod en lecture seule : `"Update failed: the iPod is read-only"`.
- Mise à jour sur un hôte : le binaire mis à jour est sur l'iPod, donc il sert ensuite sur tous les hôtes du même OS. Les binaires des autres OS restent à leur version.

---

## 5. Test et build

### Objectifs

Livrer le plug-in vérifié sur les 3 OS.

### Sous-tâches

- **YTD-7** : écrire `fixtures.json` et faire passer `ipodpromax plugin test Plug-ins/yt-dlp`.
- **YTD-8** : compiler sur les 3 OS et placer les binaires dans `Build/iPod Pro Max/Plug-ins/yt-dlp/`.

### Comportement utilisateur

- Sans objet.

### Règles d'interaction

- Le test réel télécharge un seul morceau court et libre de droits, fixé dans `fixtures.json`.

### États visuels

- Sans objet.

### Edge cases

- Aucun.

---

## Hors périmètre

- Autres sites gérés par yt-dlp (SoundCloud, Bandcamp) comme résolveurs. On pourra les ajouter plus tard avec le même plug-in.
- Abonnements à des chaînes YouTube en podcast. Prévu à l'étape Podcasts, avec un rôle à définir.

## Questions ouvertes

1. Si Deno est nécessaire, la taille ajoutée sur l'iPod (environ 40 à 100 Mo par OS) est-elle acceptable ?
2. Faut-il demander une confirmation avant d'utiliser yt-dlp pour chaque morceau, ou suffit-il du réglage `"Accept YouTube when nothing else is found"` ?
