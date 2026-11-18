# Plug-in Soulseek : recherche, téléchargement et partage

Contrat : [[feature-plugins]]. Utilisé par : [[feature-playlist-subscriptions]].

## Cadre

- **Rôles** : `resolver`, `downloader`, `share`. `requiresConsent: "p2p"`.
- **Client natif en Swift**, sans démon externe (pas de slskd), sans Node, sans `slsk-client`.
- **Portabilité** : macOS d'abord, mais **avec le moins de réécriture possible pour Windows et Linux**. Tout le protocole est en Foundation pur ; seule la couche socket dépend de l'OS, et elle est isolée (section 1).
- **Sources d'inspiration** :
  1. **seeleseek** (https://github.com/bretth18/seeleseek, MIT, client macOS en Swift maintenu, moteur dans `Packages/SeeleseekCore`).
     - **À reprendre**, en gardant la mention de licence MIT et l'origine en tête de chaque fichier :
       - `Network/Protocol/` : `MessageCode`, `MessageBuilder`, `MessageParser`, `ObfuscationCodec`, `DataExtensions`, `Decompression` ;
       - `Models/` : `SearchResult`, `Transfer`, `SharedFile`, `User`, `SearchQuery`.
     - **À adapter** : `Compression` → zlib (cible C, ou zlib système sur Linux) ; `CryptoKit` (MD5 de connexion) → MD5 portable ; `os.Logger` → `$/log`.
     - **À réécrire** : `Network/Connections/*` et `ListenerService` (`Network.framework`) ; `NATService` (Darwin et SystemConfiguration).
     - **Référence de comportement seulement** : `DownloadManager.swift` et `UploadManager.swift` (trop gros et trop liés à leur interface), ainsi que `NetworkClient+Distributed.swift` (phase 2).
  2. **L'ancien projet de Julien** (`~/Desktop/Coding/Spotify-Soulseek-Downloader/src/soulseek/soulseek.ts`) : construction des requêtes, élargissement de la recherche, et la leçon du commit `a5c7786` (ne pas couper la recherche après 1,2 s de silence, car des pairs lents mais valides répondent plus tard). Sa note des candidats ne vit plus ici, mais dans le cœur.
- Sous-tâches : SLSK-1 à SLSK-16.

## Vue d'ensemble

| Section | Sous-tâches |
| --- | --- |
| 1. Transport portable et protocole | SLSK-1, SLSK-2, SLSK-3 |
| 2. Identité et connexion | SLSK-4, SLSK-5 |
| 3. Recherche | SLSK-6, SLSK-7 |
| 4. Téléchargement | SLSK-8, SLSK-9, SLSK-10 |
| 5. Partage | SLSK-11, SLSK-12, SLSK-13 |
| 6. Réglages et état | SLSK-14 |
| 7. Mesures, test et build | SLSK-15, SLSK-16 |

**Avant toute la suite, faire un spike** (SLSK-1 à SLSK-6) **sur les 3 OS** : identité automatique et connexion, puis recherche « Olivia Dean Man I Need » avec plus de 50 réponses reçues et décodées. Ce spike décide si l'approche tient.

---

## 1. Transport portable et protocole

### Objectifs

Parler le protocole Soulseek depuis du Swift qui compile sur les 3 OS, en reprenant le travail de seeleseek pour la partie protocole et en isolant tout ce qui dépend de l'OS dans une couche mince.

### Sous-tâches

- **SLSK-1** : créer une cible C `CSockets` (BSD sockets sur macOS et Linux, Winsock sur Windows, un fil de `poll`/`WSAPoll`) et un protocole Swift `SocketTransport` au-dessus (`connect`, `listen`, `read`, `write`, `close`, en `async`).
- **SLSK-2** : reprendre la couche protocole et les modèles de seeleseek, avec zlib et MD5 portables.
- **SLSK-3** : écrire des tests unitaires du protocole sur des messages enregistrés (octets → modèles → octets).

### Comportement utilisateur

- Rien de visible.

### Règles d'interaction

- Le reste du plug-in ne voit que `SocketTransport`. Porter le plug-in sur Windows ou Linux, c'est compiler `CSockets`, rien d'autre.
- SwiftNIO est l'alternative : solide sur macOS et Linux, mais son support Windows doit être vérifié. **On ne l'adopte pas sans ce test.**
- Messages nécessaires en v1 :
  - serveur : `Login`, `SetWaitPort`, `GetPeerAddress`, `ConnectToPeer`, `FileSearch`, `SetStatus`, `SharedFoldersFiles`, `CantConnectToPeer` ;
  - pair : `PeerInit`, `PierceFirewall`, `FileSearchResponse` (zlib), `GetSharedFileList` / `SharedFileListResponse` (zlib), `TransferRequest`, `TransferResponse`, `QueueUpload`, `PlaceInQueueResponse`, `UploadFailed`, `UploadDenied`.

### États visuels

- Aucun.

### Edge cases

- zlib sur Windows : vérifier pendant le spike s'il faut compiler zlib dans une cible C, ou si une version est déjà disponible.

---

## 2. Identité et connexion

### Objectifs

Se connecter au réseau **sans inscription** : le plug-in crée tout seul une identité, qui reste la même d'un ordinateur à l'autre puisqu'elle est enregistrée sur l'iPod. Un utilisateur qui le souhaite peut quand même saisir son propre compte.

### Sous-tâches

- **SLSK-4** : générer, enregistrer et réutiliser l'identité automatique.
- **SLSK-5** : connexion au serveur, reconnexion, et choix entre identité automatique et compte personnel (bloc `account`).

### Comportement utilisateur

- À la première activation, l'utilisateur n'a rien à saisir. La carte Soulseek affiche `"Connected as ipod-7f3k2q"`.
- S'il préfère son compte, il choisit `"My account"`, saisit son nom et son mot de passe, puis clique `"Sign In"`.

### Règles d'interaction

- **Identité automatique** :
  - générée à la première connexion : nom `ipod-` suivi de 6 caractères `[a-z0-9]`, mot de passe de 24 caractères aléatoires ;
  - enregistrée dans `Persistent Data/Plug-ins/soulseek/secrets.json` ;
  - le serveur Soulseek crée automatiquement un compte inconnu à la première connexion.
- **Nom déjà pris** (`INVALIDPASS`) avec l'identité automatique : on en génère une autre, 3 essais au plus. Avec un compte personnel, on affiche `"Wrong username or password."` et on ne régénère rien.
- **Serveur** : `server.slsknet.org:2242`, fixé dans `config` (manifeste).
- **Moment de la connexion** : à la première recherche, ou au démarrage de l'app si le partage est activé. Jamais pour dessiner les Préférences.
- **Perte de connexion** : reconnexion après 5 s, puis 15 s, puis 60 s, seulement tant qu'une opération ou le partage en a besoin. C'est un délai lié à l'opération, pas une interrogation.
- **Bloc `account`** : choix `"Automatic identity"` (par défaut) / `"My account"`. Avec l'identité automatique, le bloc affiche le nom et le bouton `"New Identity"`, qui en génère une autre après confirmation.

### États visuels

- **Connecting** : `"Connecting…"` et la pastille d'activité de la carte.
- **Connected** : `"Connected as <nom>"`.
- **Error** : `"Can't connect to Soulseek"` ou `"Wrong username or password."`, en rouge.
- **Idle** (pas de connexion en cours, rien à faire) : `"Not connected"`, en gris. C'est l'état normal au repos quand le partage est désactivé.

### Edge cases

- Le serveur exclut le compte parce qu'il s'est connecté ailleurs (même identité sur un autre ordinateur au même moment) : `"Signed in from another computer"`, sans reconnexion automatique.
- `secrets.json` perdu : une nouvelle identité est créée. L'ancienne n'est pas récupérable.

---

## 3. Recherche

### Objectifs

Trouver vite les fichiers d'un morceau, sans rater les pairs lents qui ont souvent les meilleures versions.

### Sous-tâches

- **SLSK-6** : rôle `resolver` : requête, réception des réponses (`FileSearchResponse` compressé), conversion en `Candidate` et envoi au fil de l'eau (`resolver/candidates`).
- **SLSK-7** : fenêtre de recherche, arrêt anticipé et élargissement de la requête.

### Comportement utilisateur

- Dans la vue de la playlist, le morceau affiche « Searching Soulseek… » quelques secondes, puis passe au téléchargement.

### Règles d'interaction

- **Requête** : `<artiste principal> <titre>`, nettoyée (parenthèses `feat.` retirées, ponctuation remplacée par des espaces). Si rien n'est accepté, deuxième requête `<titre> <album>`, puis troisième requête `<titre>` seul **si le titre fait au moins 3 mots**. On reprend l'élargissement de l'ancien projet.
- **Fenêtre de recherche** : réglage `searchWindowSeconds`, valeur de départ 8 s, **à mesurer** (SLSK-15).
- **Arrêt anticipé** : le cœur peut arrêter la recherche dès qu'un candidat sans perte, avec créneau libre, est accepté. Il le fait par `$/cancelRequest`, et le plug-in renvoie alors les candidats déjà reçus.
- **`Candidate`** :
  - `token` = utilisateur + chemin complet ;
  - `displayName` = chemin ;
  - `container`, `bitrateKbps`, `durationMs`, `sampleRateHz`, `bitDepth` : depuis les attributs du fichier. Si un attribut manque, on le déduit du nom de fichier (extension, « 320 ») ;
  - `availability` = créneau libre, longueur de file, vitesse annoncée.
- On ne garde que les fichiers audio (`flac`, `alac`/`m4a`, `mp3`, `aac`, `ogg`, `opus`, `wav`, `aiff`). Les dossiers verrouillés (privés) sont exclus.

### États visuels

- Aucun en propre (colonne d'état du moteur).

### Edge cases

- Plus de 2 000 réponses : on garde les 500 premiers fichiers audio et on ignore le reste.
- Aucune réponse au bout de la fenêtre : liste vide. Le cœur passe à la requête élargie ou au résolveur suivant.
- Le serveur limite les recherches : le cœur ne lance jamais plus de 3 recherches en même temps (voir [[feature-playlist-subscriptions]], section 6).

---

## 4. Téléchargement

### Objectifs

Télécharger de manière fiable le candidat choisi, que l'autre pair soit derrière un pare-feu ou non, avec reprise et annulation propres.

### Sous-tâches

- **SLSK-8** : connexions aux pairs, directes et indirectes (`ConnectToPeer`, `PierceFirewall`).
- **SLSK-9** : rôle `downloader` : `QueueUpload`, `TransferRequest`/`TransferResponse`, connexion de type `F`, réception avec reprise (offset), `PlaceInQueue`, erreurs.
- **SLSK-10** : annulation propre d'une recherche ou d'un téléchargement (`$/cancelRequest`).

### Comportement utilisateur

- Le morceau affiche « Downloading from Soulseek – 42% », puis devient disponible.
- Si l'autre pair le met en file d'attente, l'info-bulle indique `"Queued (position 3)"`.

### Règles d'interaction

- Écriture dans `destinationDir` (dossier temporaire du cœur) sous `<nom>.part`. Le plug-in renvoie le chemin quand le fichier est complet. Le déplacement final et la vérification sont faits par le cœur.
- `$/progress` : octets reçus et taille totale, au plus 4 fois par seconde.
- **Délai** :
  - si le pair ne répond pas à `QueueUpload` en 20 s : échec `network` ;
  - si le pair met en file d'attente et que la position ne diminue pas en 3 minutes : échec `unsupported` (« queue too long »), et le cœur passe au candidat suivant.
- **Reprise** : si un `.part` du même fichier existe déjà, on demande la suite à partir de sa taille.
- **Erreurs du pair** : `UploadDenied` (raison en anglais, transmise), `UploadFailed` → échec, et le cœur passe au candidat suivant.

### États visuels

- Aucun en propre (colonne d'état du moteur).

### Edge cases

- Les deux pairs sont derrière un pare-feu sans port ouvert : la connexion est impossible, et on échoue dans le délai prévu. UPnP est prévu en phase 2.
- Le pair coupe en cours de transfert : le `.part` est gardé pour une reprise lors d'un prochain essai avec le même candidat, sinon il est supprimé par le cœur.
- Annulation pendant la file d'attente chez le pair : on envoie l'annulation du transfert au pair si le protocole le permet, et on ferme la connexion.

---

## 5. Partage

### Objectifs

Partager par défaut, en servant réellement les fichiers annoncés, sans fatiguer l'iPod et sans aucun travail quand personne ne demande rien.

### Sous-tâches

- **SLSK-11** : rôle `share` : recevoir l'index (`share/setIndex`) et annoncer `SharedFoldersFiles`.
- **SLSK-12** : répondre à la navigation (`GetSharedFileList` → `SharedFileListResponse` compressé).
- **SLSK-13** : envois : créneaux, file d'attente, lecture séquentielle.

### Comportement utilisateur

- Rien à faire : le partage est actif par défaut une fois le plug-in activé et le consentement donné.
- La carte affiche par exemple `"Sharing 1,234 files in 56 folders · 1 upload"`.
- L'utilisateur peut couper le partage avec `"Share my music"`.

### Règles d'interaction

- **Quoi partager** : c'est l'app qui le décide et qui envoie l'index (voir [[feature-playlist-subscriptions]], section 9). Le plug-in sert exactement cet index, ni plus ni moins.
- **Annonce** : `SharedFoldersFiles` avec les nombres de dossiers et de fichiers réels de l'index, envoyée à la connexion et à chaque nouvel index.
- **Créneaux** : la valeur `uploadSlots` reçue avec l'index (1 si l'index vient de l'iPod, 2 si il vient de l'hôte). Au-delà, les demandes vont en file d'attente, avec `PlaceInQueueResponse`.
- **Lecture** : séquentielle, par blocs de 256 Kio, un seul fichier lu à la fois depuis l'iPod. Un iPod Classic à disque dur ou une carte SD en FAT32 supporte mal les lectures en parallèle.
- **Fichier demandé absent de l'index** : `UploadDenied` (« File not shared. »).
- **Durée de vie** : le partage ne fonctionne que pendant que l'app est ouverte. Quand l'app se ferme, les envois en cours sont interrompus.
- **Phase 2** : réseau distribué, pour **répondre aux recherches** des autres. Sans lui, nos fichiers ne sont trouvables que par navigation dans nos partages, mais ils comptent déjà dans nos statistiques de partage.

### États visuels

- Carte : `"Sharing <n> files in <m> folders"` / `"Sharing your iPod: <n> files"` / `"Not sharing"`, avec `" · <k> upload(s)"` quand des envois sont en cours.

### Edge cases

- Un fichier de l'index a disparu au moment de l'envoi : `UploadFailed`, et il est retiré de l'index jusqu'au prochain envoi de l'index par l'app.
- iPod éjecté pendant un envoi depuis l'iPod : l'envoi échoue proprement. L'éjection n'est pas bloquée plus de 2 s par le plug-in.
- Partage coupé pendant des envois : les envois en cours se terminent, mais aucun nouveau n'est accepté. À confirmer.

---

## 6. Réglages et état

### Objectifs

Donner à l'utilisateur les quelques réglages utiles, et lui montrer clairement l'état de la connexion et du partage.

### Sous-tâches

- **SLSK-14** : déclarer les réglages dans le manifeste et envoyer l'état (`$/status`).

### Comportement utilisateur

- Dans Préférences → Plug-ins → Soulseek, il voit son identité, l'état de la connexion et du partage, et quelques réglages avancés.

### Règles d'interaction

- Réglages, dans cet ordre :

| Clé | Type | Libellé | Défaut |
| --- | --- | --- | --- |
| `account` | `account` | `"Identity"` (automatique ou compte personnel) | automatique |
| `share` | `bool` | `"Share my music"` | vrai |
| `listenPort` | `int` | `"Listening port"` (1024 à 65535) | 2234 |
| `maxDownloads` | `int` | `"Simultaneous downloads"` (1 à 6) | 4 |
| `searchWindowSeconds` | `int` | `"Search time"`, unité `s` (3 à 20) | 8, à mesurer |

- Le nombre d'envois simultanés n'est **pas** réglable : 1 depuis l'iPod, 2 depuis l'hôte.

### États visuels

- Voir les sections 2 et 5.

### Edge cases

- Port d'écoute déjà pris : on essaie les 10 ports suivants, puis on continue sans écoute. Les connexions passent alors seulement de façon indirecte, et un avertissement s'affiche dans la carte.

---

## 7. Mesures, test et build

### Objectifs

Régler la fenêtre de recherche sur des mesures réelles, et livrer le plug-in vérifié sur les 3 OS.

### Sous-tâches

- **SLSK-15** : mesurer `searchWindowSeconds` sur 50 morceaux réels : taux trouvé et temps jusqu'au premier candidat accepté, selon la fenêtre (4, 6, 8 et 12 s). Résultats notés dans `Docs/`.
- **SLSK-16** : écrire `fixtures.json`, faire passer `ipodpromax plugin test Plug-ins/Soulseek`, et compiler sur les 3 OS.

### Comportement utilisateur

- Sans objet.

### Règles d'interaction

- La mesure tourne avec `Tools/` (script reproductible), jamais à l'intérieur de l'app.

### États visuels

- Sans objet.

### Edge cases

- Les résultats varient selon l'heure : mesurer à deux moments de la journée.

---

## Hors périmètre

- Réseau distribué (répondre aux recherches) et ouverture automatique du port (UPnP/NAT-PMP, avec `NATService.swift` comme référence) : phase 2.
- Messagerie, salons, liste d'amis, navigation dans les partages des autres.
- Téléchargement d'albums complets d'un même pair.

## Questions ouvertes

1. Quand on coupe le partage, faut-il laisser se terminer les envois en cours ou les arrêter tout de suite ?
2. Faut-il afficher l'identité automatique (`ipod-xxxxxx`) dans l'interface, ou la cacher pour simplifier ?
3. Faut-il, plus tard, partager aussi les livres audio et les podcasts ?
