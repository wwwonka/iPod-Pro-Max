# Plug-in Spotify : source de playlists sans API officielle

Contrat : [[feature-plugins]]. Utilisé par : [[feature-playlist-subscriptions]].

## Cadre

- **Rôle** : `playlistSource` seulement. Le plug-in ne télécharge rien. `requiresConsent: "scraping"`.
- **Point essentiel** : il **n'utilise pas l'API Web officielle de Spotify**. Il n'y a pas d'application à enregistrer, pas de Client ID, et pas besoin de Premium. C'est la raison d'être du scraper de Julien.
- **Référence à porter en Swift** : `~/Desktop/Coding/Spotify-Soulseek-Downloader/src/scraper/` (TypeScript, environ 1 750 lignes : `index.ts`, `token.ts`, `pathfinder.ts`, `parsers.ts`, `urls.ts`, `errors.ts`, `types.ts`).
  - Le `README.md` de ce projet est périmé : il décrit encore l'API officielle. C'est le code qui fait foi.
  - **Ne pas copier** `.spotify-tokens.json`, `.spotify-s-browser-token.json` ni `config.json` : ils contiennent des jetons et des identifiants personnels.
- **Modèle pour les futures sources** (YouTube Music, Deezer, Apple Music, SoundCloud, Bandcamp) : la structure de ce plug-in doit être un exemple propre et commenté.
- **Plateformes** : Foundation et `URLSession` seulement, identiques sur les 3 OS.
- Sous-tâches : SPO-1 à SPO-10.

## Vue d'ensemble

| Section | Sous-tâches |
| --- | --- |
| 1. Reconnaître une URL | SPO-1, SPO-2 |
| 2. Jeton anonyme | SPO-3 |
| 3. Lire une playlist ou un album | SPO-4, SPO-5, SPO-6 |
| 4. Détecter les changements | SPO-7 |
| 5. Résister aux changements de Spotify | SPO-8 |
| 6. Paquet, test et build | SPO-9, SPO-10 |

---

## 1. Reconnaître une URL

### Objectifs

Reconnaître, sans lancer de processus, toutes les formes de lien qu'un utilisateur peut copier depuis Spotify, et en tirer le type et l'identifiant.

### Sous-tâches

- **SPO-1** : déclarer les `urlPatterns` du manifeste.
- **SPO-2** : écrire l'analyse d'URL côté plug-in (`SpotifyURL`), à partir de `urls.ts`.

### Comportement utilisateur

- L'utilisateur colle n'importe quel lien Spotify de playlist ou d'album dans `"New Subscription"`. Le logo Spotify apparaît dans le champ.

### Règles d'interaction

- Formes acceptées :
  - `https://open.spotify.com/playlist/<id>` et `…/album/<id>` ;
  - avec un préfixe de langue `/intl-fr/`, `/intl-pt-BR/` ;
  - avec des paramètres (`?si=…`, `?pi=…`) ;
  - sans `https://` ;
  - URI `spotify:playlist:<id>` et `spotify:album:<id>`.
- `<id>` : 22 caractères `[0-9A-Za-z]`.
- Les liens de morceau, d'artiste, de podcast et d'épisode ne sont **pas** acceptés en v1.
- Les liens courts `spotify.link/…` et `spoti.fi/…` ne sont pas acceptés en v1. À confirmer.

### États visuels

- Badge Spotify dans le champ de `"New Subscription"` (voir [[feature-playlist-subscriptions]], section 1).

### Edge cases

- Identifiant de mauvaise longueur : pas de correspondance, « This link isn't supported. »
- Lien d'une playlist générée par Spotify (Discover Weekly, Daily Mix) : accepté. Le contenu change chaque semaine, et l'abonnement le suit comme une playlist ordinaire.

---

## 2. Jeton anonyme

### Objectifs

Obtenir sans compte un jeton qui autorise les appels à l'API interne de Spotify, comme le fait le lecteur intégré des pages web.

### Sous-tâches

- **SPO-3** : écrire `TokenManager` (actor) en portant `token.ts`.

### Comportement utilisateur

- Rien de visible. Aucun compte n'est demandé.

### Règles d'interaction

- **Amorçage** :
  1. `GET https://open.spotify.com/embed/playlist/<id>` (l'id de la playlist demandée, ou celui de l'ancien code par défaut) ;
  2. extraire le JSON du `<script id="__NEXT_DATA__" type="application/json">` ;
  3. lire `props.pageProps.state.settings.session` : `accessToken`, `accessTokenExpirationTimestampMs`, `isAnonymous`.
- Le jeton est gardé en mémoire seulement, jamais sur disque, puisqu'il est anonyme et court. Il est renouvelé quand il reste moins de 60 s avant son expiration.
- **Un seul amorçage à la fois** : les appels qui arrivent pendant un amorçage attendent son résultat.
- Sur un 401 d'un appel pathfinder : on invalide le jeton, on refait l'amorçage, et on réessaie **une seule fois**.
- En-tête `User-Agent` : celui d'un navigateur de bureau courant, fixé dans `config` (manifeste) pour pouvoir le changer sans recompiler.

### États visuels

- Aucun.

### Edge cases

- `__NEXT_DATA__` absent ou de forme différente : erreur `apiChanged`, avec le chemin JSON qui manquait dans le journal.
- Page embed bloquée (403, captcha) : erreur `network` avec le code HTTP, sans boucle de nouvelles tentatives.

---

## 3. Lire une playlist ou un album

### Objectifs

Renvoyer la playlist ou l'album complet, tous les morceaux et toutes les pages, sous forme de `TrackRef` aussi complets que possible.

### Sous-tâches

- **SPO-4** : écrire les appels pathfinder (`fetchPlaylist`, `getAlbum`) en portant `pathfinder.ts`.
- **SPO-5** : écrire les parsers vers `Playlist` et `TrackRef` en portant `parsers.ts`.
- **SPO-6** : gérer la pagination et les limites de débit.

### Comportement utilisateur

- Après `"Subscribe"`, la playlist apparaît en quelques secondes avec tous ses morceaux, même s'il y en a plusieurs centaines.

### Règles d'interaction

- **Appel** : `GET https://api-partner.spotify.com/pathfinder/v1/query`, avec `operationName`, `variables` (JSON) et `extensions` (`{"persistedQuery":{"version":1,"sha256Hash":"<hash>"}}`), et l'en-tête `Authorization: Bearer <jeton>`.
- **Opérations utilisées en v1** : `fetchPlaylist` (pages de 100, variables `uri`, `offset`, `limit`, `enableWatchFeedEntrypoint: false`) et `getAlbum` (pages de 50, variables `uri`, `locale: ""`, `offset`, `limit`). Les hash sont dans `config.pathfinder` (section 5).
- **Pagination** : suivre `contents.offsets.nextOffset` (playlist) ou `tracks.offsets.nextOffset` (album) jusqu'à ce qu'il soit nul. L'ancien code s'arrêtait à 10 pages ; **on retire cette limite**, et on s'arrête seulement à 100 pages, soit 10 000 morceaux, avec un avertissement.
- **Une requête à la fois** par appel `source/fetch` : les pages sont lues l'une après l'autre.
- **Limite de débit (429)** : attendre `Retry-After` (au plus 30 s), puis réessayer, 3 fois au plus. Ensuite, erreur `rateLimited` avec `retryAfterSeconds`.
- **Correspondance des champs** :
  - `uri` → `sourceID` (seulement l'id) ;
  - `name` → `title` ;
  - `artists.items[].profile.name` → `artists` ;
  - `albumOfTrack.name` → `album` ;
  - `albumOfTrack.artists` → `albumArtist` (premier artiste) ;
  - `trackNumber`, `discNumber` ;
  - `duration.totalMilliseconds` → `durationMs` ;
  - plus grande image de `albumOfTrack.coverArt.sources` → `artworkURL` ;
  - date de sortie → `releaseDate` ;
  - `contentRating.label == "EXPLICIT"` → `explicit`.

  ISRC : seulement si pathfinder l'expose ; sinon `nil`. À vérifier.
- **Éléments ignorés** : épisodes de podcast et fichiers locaux d'une playlist (sans `uri` de morceau), et morceaux indisponibles (`playability.playable == false`), qui sont quand même renvoyés, mais marqués dans le journal.
- **Playlist** : `name` → `title`, `ownerV2.data.name` → `owner`, plus grande image → `artworkURL`.

### États visuels

- Aucun en propre. La fenêtre `"New Subscription"` affiche son indicateur pendant tout l'appel.

### Edge cases

- Playlist privée ou supprimée : erreur `notFound`.
- Morceau sans album (single) : `album` est le titre du single, comme dans Spotify.
- Même morceau deux fois dans la playlist : il apparaît deux fois dans `tracks`, puisque l'ordre est respecté. Le moteur ne le télécharge qu'une fois.
- Plus de 10 000 morceaux : on renvoie les 10 000 premiers, et le journal le signale.

---

## 4. Détecter les changements

### Objectifs

Éviter tout travail inutile quand une playlist n'a pas changé depuis la dernière synchro.

### Sous-tâches

- **SPO-7** : calculer `Playlist.revision`.

### Comportement utilisateur

- Une mise à jour d'une playlist qui n'a pas bougé prend environ une seconde.

### Règles d'interaction

- `revision` = SHA-256 (implémentation portable, sans `CryptoKit`) du titre, suivi de la liste ordonnée des `sourceID` séparés par `\n`, en hexadécimal.
- La revision ne dépend ni de l'heure ni du jeton : deux lectures d'une playlist inchangée donnent la même valeur.

### États visuels

- Aucun.

### Edge cases

- Changement de pochette ou de description seulement : même revision, donc rien ne bouge. C'est voulu.

---

## 5. Résister aux changements de Spotify

### Objectifs

Spotify change régulièrement les hash de ses requêtes persistées. Il faut pouvoir corriger ça **sans recompiler**, et donner à l'utilisateur un message compréhensible.

### Sous-tâches

- **SPO-8** : sortir les opérations pathfinder dans `config` et classer les erreurs de l'API.

### Comportement utilisateur

- Quand Spotify casse le plug-in, l'utilisateur lit `"Spotify changed how it works. Update the Spotify plug-in."` dans la vue de la playlist et dans la carte du plug-in, au lieu d'une erreur technique.

### Règles d'interaction

- `plugin.json` → `config.pathfinder` : `{"fetchPlaylist": {"sha256": "a65e1219…"}, "getAlbum": {"sha256": "b9bfabef…"}, …}`. Les valeurs de départ sont celles de `pathfinder.ts`. Le code ne contient que la construction des variables.
- Une réponse `PersistedQueryNotFound` (ou un champ attendu absent, comme `playlistV2`) donne l'erreur `apiChanged`, et `$/status` passe à `{state: "error", message: "Spotify changed how it works. Update the Spotify plug-in."}`.
- Le `README.md` du plug-in explique comment retrouver un hash : open.spotify.com, outils de développement, onglet Réseau, filtre `pathfinder`, champ `sha256Hash`.

### États visuels

- Carte du plug-in en état « Error » avec ce message (voir [[feature-plugins]], section 4).

### Edge cases

- Un seul hash périmé (par exemple `getAlbum`) : seules les URL d'album échouent ; les playlists continuent de fonctionner.

---

## 6. Paquet, test et build

### Objectifs

Livrer le plug-in sur les 3 OS, vérifié par le test de conformité, comme exemple pour toutes les futures sources.

### Sous-tâches

- **SPO-9** : écrire le manifeste, `badge.svg`, `Tests/fixtures.json` (URL d'exemple et réponses JSON enregistrées) et le `README.md` du plug-in.
- **SPO-10** : ajouter la cible au `Package.swift` racine et la compiler sur les 3 OS dans `Tools/Build/`.

### Comportement utilisateur

- Le plug-in Spotify est présent dès l'installation de l'app, désactivé jusqu'au consentement.

### Règles d'interaction

- Structure :

```
Plug-ins/Spotify/
├─ plugin.json
├─ badge.svg             logo Spotify monochrome, un seul tracé (repris de Resources/Symbols/spotify.svg)
├─ README.md             fonctionnement et procédure pour retrouver un hash
├─ Sources/SpotifyPlugin/
│  ├─ main.swift          PluginMain.run(roles: [SpotifySource()])
│  ├─ SpotifySource.swift  conformité à PlaylistSource
│  ├─ SpotifyURL.swift
│  ├─ TokenManager.swift
│  ├─ Pathfinder.swift
│  └─ Parsers.swift
└─ Tests/fixtures.json
```

- Les tests des parsers utilisent des réponses enregistrées et n'appellent pas le réseau. Un test avec le marqueur « réseau » lit une vraie playlist publique ; il ne tourne qu'à la demande.
- `ipodpromax plugin test Plug-ins/Spotify` doit passer sur les 3 OS.

### États visuels

- Aucun.

### Edge cases

- Aucun.

---

## Hors périmètre

- **Playlists privées** par OAuth PKCE. L'ancien code accepte déjà un jeton OAuth à la place du jeton anonyme (`setOAuthToken`), sans Premium. On l'ajoutera en v2, par un réglage `account` avec `oauth: true` ([[feature-plugins]], section 5).
- Recherche dans Spotify, pages d'artiste, podcasts.
- Rôle `metadataProvider` (Spotify comme source de tags pour le Metadata Editor). Possible plus tard avec le même code.

## Questions ouvertes

1. Accepter les liens courts `spotify.link/…`, qui demandent une redirection HTTP de plus ?
2. Faut-il prévoir dès la v1 les playlists privées (OAuth), ou les publiques suffisent-elles pour commencer ?
