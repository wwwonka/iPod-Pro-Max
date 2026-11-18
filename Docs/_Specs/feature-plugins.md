# Plug-ins : architecture, contrat et paquets

Source : échanges avec Julien du 15 novembre 2026. Décision : [[ADR-007 Plug-ins hors processus]].
Specs liées : [[feature-playlist-subscriptions]], [[feature-plugin-spotify]], [[feature-plugin-soulseek]], [[feature-plugin-ytdlp]].

## Cadre

- **Périmètre** : le système de plug-ins de l'app (contrat, exécution, installation, réglages, outils pour les développeurs). Neuf chantiers, découpés en sous-tâches numérotées de PLG-1 à PLG-16. Les plug-ins eux-mêmes ont chacun leur spec.
- **Pour qui** : un agent qui implémente le système, puis tous les agents qui écriront ensuite des plug-ins. Cette spec est leur référence. **Elle ne contient pas d'implémentation.**
- **Plateformes** : macOS est la cible prioritaire en ce moment, mais **tout doit pouvoir être porté sur Windows et Linux avec un minimum de réécriture**. Concrètement :
  - Foundation uniquement dans `PluginKit` et dans les plug-ins ;
  - interdits : `Network.framework`, `Combine`, `os.Logger`, `CryptoKit`, `Compression`, AppKit ;
  - ce qui dépend vraiment de l'OS est isolé dans un fichier ou une cible C.

  Les raccourcis sont notés à la manière de macOS ; sur Windows et Linux, Ctrl remplace ⌘ et Alt remplace ⌥.
- **Langue** : les textes de l'interface sont en anglais, comme le reste de l'app. Ils sont écrits entre guillemets droits dans cette spec (`"Install Plug-in…"`).
- **Performance** (AGENTS.md) : un plug-in ne coûte rien au repos. Aucun minuteur, aucune interrogation périodique ; un processus de plug-in ne vit que le temps d'une opération.
- **Statut du contenu** : ce qui est marqué « À confirmer » est une proposition, reprise dans les Questions ouvertes.

## Vue d'ensemble

| Section | Sous-tâches |
| --- | --- |
| 1. Rôles et types communs | PLG-1, PLG-2 |
| 2. Exécution hors processus | PLG-3, PLG-4 |
| 3. Registre et emplacement sur le disque | PLG-5, PLG-6 |
| 4. Onglet Plug-ins des Préférences | PLG-7, PLG-8, PLG-9 |
| 5. Comptes | PLG-10 |
| 6. Consentement à l'activation | PLG-11 |
| 7. Paquet `.ippmplugin` et installation | PLG-12, PLG-13 |
| 8. Mode développeur | PLG-14 |
| 9. Outils CLI et modèle pour les agents | PLG-15, PLG-16 |

Le protocole, le manifeste et les règles par OS sont détaillés en annexes A, B et C.

---

## 1. Rôles et types communs

### Objectifs

Définir une fois pour toutes ce qu'un plug-in peut faire, sous forme de rôles indépendants. Le cœur de l'app ne connaît que ces rôles et c'est lui qui les enchaîne. Ainsi, Spotify ne sait pas que Soulseek existe, et un nouveau service profite de tous les plug-ins déjà écrits.

### Sous-tâches

- **PLG-1** : créer le module `PluginKit` (dans `Sources/`, Foundation seulement) avec les types communs et un protocole Swift par rôle.
- **PLG-2** : y déplacer les protocoles `MetadataLookupProvider` et `LyricsLookupProvider` de MediaKit, avec leurs fournisseurs intégrés (LRCLIB, Musixmatch, MusicBrainz, AcoustID, iTunes), sans changer leur comportement.

### Comportement utilisateur

- Rien de visible. Le Metadata Editor (recherche MusicBrainz et LRCLIB) fonctionne exactement comme avant PLG-2.

### Règles d'interaction

- Rôles :

| Rôle | Entrée | Sortie | Exemples |
| --- | --- | --- | --- |
| `playlistSource` | URL | `Playlist` + liste de `TrackRef` | Spotify, YouTube Music, Deezer |
| `resolver` | `TrackRef` + politique de qualité | liste de `Candidate`, livrée au fil de l'eau | Soulseek, yt-dlp |
| `downloader` | `Candidate` + dossier temporaire | chemin du fichier + progression | Soulseek, yt-dlp |
| `share` | index de partage fourni par l'app | envois aux autres utilisateurs | Soulseek |
| `metadataProvider` | titre, artiste, album | correspondances | MusicBrainz, iTunes |
| `lyricsProvider` | titre, artiste, album, durée | paroles (LRC ou texte brut) | LRCLIB, Musixmatch |

- Un plug-in déclare un ou plusieurs rôles. **Un plug-in ne remplit jamais un pipeline complet** : il ne télécharge pas ce qu'une autre source a listé, et il n'écrit pas dans la bibliothèque.
- **Les plug-ins rapportent des faits, le cœur décide.** Un `resolver` renvoie des candidats sans les noter ; la note est calculée par le cœur (voir [[feature-playlist-subscriptions]], section 6). Un plug-in peut ajouter un indice `hint` entre 0 et 1, qui sert seulement à départager deux candidats.
- Types communs (Codable, Sendable) :

```swift
struct TrackRef {
    var source: String         // id du plug-in, ex. "spotify"
    var sourceID: String       // id dans le service
    var title: String
    var artists: [String]      // le premier est l'artiste principal
    var album: String?
    var albumArtist: String?
    var trackNumber: Int?
    var discNumber: Int?
    var durationMs: Int?
    var isrc: String?
    var releaseDate: String?   // "AAAA" ou "AAAA-MM-JJ"
    var artworkURL: URL?       // la plus grande taille disponible
    var explicit: Bool?
}

struct Playlist {
    var source: String; var sourceID: String
    var title: String; var owner: String?
    var artworkURL: URL?
    var revision: String       // change dès que le titre ou la liste ordonnée des morceaux change
}

struct Candidate {
    var resolver: String       // id du plug-in
    var token: String          // opaque, rendu tel quel au downloader du même plug-in
    var displayName: String    // chemin ou titre lisible, montré à l'utilisateur
    var title: String?; var artist: String?; var album: String?
    var durationMs: Int?
    var container: String      // "flac", "mp3", "m4a", "opus"…
    var codec: String?
    var bitrateKbps: Int?; var sampleRateHz: Int?; var bitDepth: Int?
    var sizeBytes: Int64?
    var availability: Availability?   // freeSlot: Bool, queueLength: Int, speedBytesPerSec: Int
    var hint: Double?
}
```

- Un même protocole de rôle a deux façons d'être fourni :
  - **intégré** : un type Swift dans l'app. On le réserve aux fournisseurs HTTP légers déjà présents dans MediaKit ;
  - **externe** : un exécutable séparé (section 2). L'app y accède par un adaptateur `ExternalPlugin` qui se conforme aux mêmes protocoles. **Tout nouveau service est un plug-in externe.**

### États visuels

- Aucun.

### Edge cases

- Un plug-in déclare un rôle inconnu de cette version de l'app : le rôle est ignoré et un avertissement est écrit dans le journal du plug-in. Ses autres rôles restent actifs.
- Un `downloader` reçoit un `Candidate` produit par un autre plug-in : il refuse avec l'erreur `wrongResolver`. Le cœur ne doit jamais faire cet appel.
- Le champ `hint` sort de l'intervalle 0 à 1 : il est ramené à la borne la plus proche.

---

## 2. Exécution hors processus

### Objectifs

Faire tourner chaque plug-in externe dans son propre processus. Un plug-in qui plante ou se bloque ne doit jamais faire tomber ni figer l'app, et il ne coûte rien quand on ne s'en sert pas.

### Sous-tâches

- **PLG-3** : écrire `PluginMain`, le côté plug-in de `PluginKit`. Il lit stdin, passe chaque requête au bon rôle, gère l'annulation et écrit les réponses.
- **PLG-4** : écrire `ExternalPlugin`, le côté app. Il lance le processus, fait l'`initialize`, porte plusieurs requêtes en parallèle, gère l'annulation, l'arrêt et le redémarrage après plantage.

### Comportement utilisateur

- Rien de visible quand tout va bien.
- Si un plug-in plante pendant une opération, celle-ci affiche une erreur à l'endroit concerné, par exemple dans la colonne d'état d'un morceau. L'app reste utilisable, et l'opération suivante relance le plug-in.
- Après des plantages répétés, la carte du plug-in dans les Préférences passe à l'état « Error » (section 4).

### Règles d'interaction

- **Transport** : JSON-RPC 2.0 sur stdin et stdout, **un message JSON par ligne**, en UTF-8. Le plug-in écrit ses journaux bruts sur stderr ; l'app les copie dans son journal, préfixés de l'id du plug-in. La liste des méthodes est en annexe A.
- **Lancement** : au premier appel qui concerne le plug-in, jamais au démarrage de l'app. Exception : un plug-in `share` actif est lancé au démarrage si le partage est activé (voir [[feature-plugin-soulseek]]).
- **Initialisation** : la première requête est toujours `initialize`. Le plug-in a 10 s pour répondre ; au-delà, l'app tue le processus et l'appel échoue avec `startTimeout`.
- **Fin de vie** : c'est l'opération qui a lancé le plug-in qui décide de l'arrêter. Par exemple, la fin d'une synchro d'abonnement envoie `shutdown`. Sans réponse dans les 5 s, l'app tue le processus. **Pas de délai d'inactivité mesuré par un minuteur.**
- **Partage entre opérations** : deux opérations qui ont besoin du même plug-in en même temps utilisent le même processus. Le plug-in est arrêté quand la dernière se termine.
- **Annulation** : quand l'utilisateur annule ou quitte l'app, l'app envoie `$/cancelRequest` ; le plug-in doit répondre à la requête avec l'erreur `cancelled` dans les 2 s.
- **Fermeture de l'app** : `shutdown` à tous les plug-ins, 2 s d'attente, puis on tue ceux qui restent.
- **Plantage** : un processus qui se termine sans `shutdown` fait échouer ses requêtes en cours avec l'erreur `pluginCrashed`. Le plug-in est relancé au prochain appel. Après **3 plantages en 60 s**, il passe à l'état « Error » et n'est plus relancé avant une action de l'utilisateur (« Restart » dans sa carte, ou relance de l'app).
- **Version du contrat** : `apiVersion` (un entier, 1 pour la v1) est déclaré dans le manifeste et revérifié par `initialize`. Si le plug-in demande une version supérieure à celle de l'app, il est refusé à la découverte (section 3).
- **Progression** : un plug-in envoie au plus 4 notifications `$/progress` par seconde et par requête. L'app republie la progression vers l'interface toutes les 500 ms environ, regroupée.

### États visuels

- Voir la section 4 pour les états de la carte d'un plug-in : « Ready », « Running », « Error », « Disabled ».

### Edge cases

- Le plug-in écrit sur stdout autre chose que du JSON (par exemple un `print` oublié) : la ligne est ignorée et copiée dans le journal avec l'avertissement `non-JSON line on stdout`. La connexion n'est pas coupée.
- Une ligne de plus de 16 Mio : le plug-in est arrêté avec l'erreur `messageTooLarge`. Un index de partage plus gros doit être envoyé en plusieurs morceaux (annexe A).
- L'exécutable n'existe pas, n'est pas exécutable, ou est bloqué par Gatekeeper : erreur `launchFailed` avec la raison de l'OS, et carte « Error ».
- L'app est tuée brutalement : les processus enfants restent orphelins. Ils doivent s'arrêter d'eux-mêmes quand stdin se ferme. C'est une règle de `PluginMain`, à tester.
- Deux instances de l'app lancées depuis le même iPod : hors périmètre, l'app ne le permet déjà pas.

---

## 3. Registre et emplacement sur le disque

### Objectifs

Trouver les plug-ins installés, choisir le bon exécutable pour l'OS et l'architecture, et ranger leur code et leurs données sur l'iPod, pour qu'ils suivent l'app d'un ordinateur à l'autre (ADR-006).

### Sous-tâches

- **PLG-5** : écrire le registre. Il découvre les plug-ins dans `Plug-ins/` et les plug-ins non empaquetés (section 8), lit et valide les manifestes, choisit l'exécutable, et tient `plugins.json` (plug-ins activés, ordre des résolveurs, consentements).
- **PLG-6** : faire compiler les plug-ins fournis avec l'app par `Tools/Build/build.sh`, et les faire poser dans `Build/iPod Pro Max/Plug-ins/` par `assemble-ipod.sh`, comme les applications.

### Comportement utilisateur

- Les plug-ins fournis avec l'app (Spotify, Soulseek, yt-dlp) apparaissent dans les Préférences dès le premier lancement. Ils sont **désactivés** tant que l'utilisateur n'a pas donné son consentement (section 6).

### Règles d'interaction

- Disposition :

```
<iPod>/iPod Pro Max/
├─ Plug-ins/                     code des plug-ins installés (remplacé en bloc à chaque mise à jour)
│  ├─ spotify/    plugin.json, badge.svg, bin/…, LICENSE
│  ├─ soulseek/
│  └─ yt-dlp/     plugin.json, bin/…, vendor/<os>/…
└─ Persistent Data/
   ├─ plugins.json               plug-ins activés, ordre des résolveurs, consentements donnés
   └─ Plug-ins/<id>/
      ├─ settings.json           valeurs des réglages, sauf les secrets
      ├─ secrets.json            mots de passe, jetons, identité Soulseek
      └─ Data/                   données libres du plug-in (transmises dans paths.data)
```

- Le nom du dossier sous `Plug-ins/` doit être identique à l'`id` du manifeste. Sinon, le plug-in est refusé avec le message `"Folder name doesn't match plug-in id"`.
- **Choix de l'exécutable** : clé `macos` (binaire universel), `windows-x64`, `windows-arm64`, `linux-x86_64` ou `linux-aarch64`. Sur Windows ARM64 sans entrée `windows-arm64`, on prend `windows-x64`, qui tourne par émulation.
- La découverte a lieu au démarrage de l'app, en arrière-plan (QoS `.utility`), et après chaque installation, suppression ou rechargement. Jamais à intervalle régulier.
- Les réglages de type `folder` dépendent de l'ordinateur : ils sont rangés dans `known_hosts.json`, sous l'hôte courant, et non dans `settings.json`.
- Toutes les écritures passent par l'écriture sûre déjà en place : fichier temporaire, `fsync`, renommage, puis conservation de la version précédente en `.bak`.

### États visuels

- Voir la section 4.

### Edge cases

- Manifeste illisible ou invalide : le plug-in apparaît dans les Préférences en état « Error », avec la première erreur de validation (par exemple `"plugin.json: missing field 'roles'"`).
- Aucun exécutable pour cet OS : carte grisée avec `"Not available on Windows"` (le nom de l'OS change selon le cas).
- Deux plug-ins avec le même `id` : le plug-in non empaqueté l'emporte (section 8). Entre deux plug-ins installés, c'est impossible, puisque le nom du dossier est l'`id`.
- `plugins.json` illisible : on repart de `plugins.json.bak` ; si lui aussi est illisible, tous les plug-ins sont désactivés et les consentements redemandés.
- Un plug-in est supprimé du disque alors qu'un abonnement l'utilise : l'abonnement affiche `"Plug-in 'Spotify' is missing"` (voir [[feature-playlist-subscriptions]]).

---

## 4. Onglet Plug-ins des Préférences

### Objectifs

Remplir l'onglet Plug-ins, vide aujourd'hui (`SettingsView.swift`, `case .plugins`). On y voit les plug-ins, on les active, on règle chacun **sans que l'app connaisse son contenu** : ses réglages sont décrits dans son manifeste et dessinés automatiquement. On y règle aussi l'ordre des sources de téléchargement.

### Sous-tâches

- **PLG-7** : stocker les réglages et les secrets de chaque plug-in (`settings.json`, `secrets.json`, et les réglages `folder` dans `known_hosts.json`), et transmettre les changements au plug-in en cours d'exécution.
- **PLG-8** : écrire le rendu générique des réglages déclarés dans le manifeste, en SwiftCrossUI, compilé tel quel sur les 3 OS.
- **PLG-9** : ajouter la carte « Download Sources » (ordre des résolveurs) et la carte « Downloads » (politique de qualité et dossier de téléchargement, définis dans [[feature-playlist-subscriptions]], sections 6 et 7).

### Comportement utilisateur

- L'utilisateur ouvre Préférences → Plug-ins (⌘,). Il voit une carte par plug-in, triée par nom.
- Il active ou désactive un plug-in avec une bascule. Les réglages du plug-in apparaissent sous son en-tête et prennent effet immédiatement, sans bouton « Save ».
- Dans « Download Sources », il réordonne les sources par glisser-déposer. La première est essayée en premier.

### Règles d'interaction

- **En-tête de carte** : badge du service (s'il y en a un), nom, version, une ligne de description, puis la bascule d'activation à droite. Sous le nom, les rôles en petites étiquettes (`Playlists`, `Search`, `Download`, `Sharing`, `Metadata`, `Lyrics`).
- **Corps de carte** : les réglages, dans l'ordre du manifeste. Types possibles :

| Type | Contrôle | Options du manifeste |
| --- | --- | --- |
| `bool` | bascule | |
| `string` | champ texte | `placeholder` |
| `secret` | champ masqué, avec un bouton œil pour afficher | |
| `int` | champ numérique avec flèches | `min`, `max`, `unit` |
| `enum` | menu déroulant | `options: [{value, label}]` |
| `orderedList` | liste réordonnable par glisser-déposer | `options` |
| `folder` | chemin et bouton `"Choose…"`, plus `"Reset"` si une valeur par défaut existe | valeur par défaut fournie par l'app (`default: "downloads"`) |
| `account` | bloc compte (section 5) | `fields` ou `oauth: true` |
| `action` | bouton | `label`, et une méthode `action/<key>` appelée sur le plug-in |
| `note` | texte d'aide grisé, sans valeur | `text` |

- Chaque réglage peut avoir `help` (texte gris sous le contrôle) et `visibleIf` (`{key, equals}`) pour n'apparaître que selon la valeur d'un autre réglage.
- **Enregistrement** : à chaque modification, regroupé : 500 ms après la dernière frappe dans un champ texte, et immédiatement pour une bascule ou un menu. Si le plug-in tourne, il reçoit `settings/changed`.
- **Désactiver** un plug-in : les opérations en cours qui l'utilisent sont annulées après confirmation (`"Spotify is in use. Disable it anyway?"`, boutons `"Disable"` et `"Cancel"`), puis le processus est arrêté. Ses réglages sont conservés.
- **Restart** : le bouton n'apparaît qu'en état « Error ». Il remet le compteur de plantages à zéro.
- **« Download Sources »** : la liste contient seulement les plug-ins activés qui ont le rôle `resolver`. Par défaut : Soulseek, puis yt-dlp. Un plug-in désactivé disparaît de la liste mais garde sa place, qu'il retrouve à sa réactivation.
- Une note fixe en bas de l'onglet : `"Plug-in passwords and tokens are stored on this iPod, unencrypted."`

### États visuels

- **Disabled** : carte en opacité réduite, réglages masqués, bascule éteinte.
- **Ready** : bascule allumée, sans pastille.
- **Running** : petite pastille d'activité à côté du nom pendant que le processus tourne.
- **Error** : pastille rouge, message d'erreur sur une ligne sous l'en-tête, bouton `"Restart"`.
- **Not available** : carte grisée, `"Not available on <OS>"`, bascule désactivée.
- **Onglet vide** (aucun plug-in trouvé) : `"No plug-ins installed."`, comme aujourd'hui, avec le bouton `"Install Plug-in…"`.

### Edge cases

- Valeur hors bornes dans un champ `int` : ramenée à la borne à la sortie du champ, sans message.
- Un réglage disparaît du manifeste après une mise à jour : sa valeur reste dans `settings.json` mais n'est plus affichée ni transmise.
- Une valeur de `settings.json` ne correspond plus au type déclaré : on utilise la valeur par défaut, et l'avertissement va dans le journal.
- Le dossier choisi pour un réglage `folder` n'existe plus sur cet ordinateur : chemin affiché en rouge avec `"Folder not found"`, et le plug-in reçoit la valeur par défaut.
- Fenêtre étroite : les cartes passent sur une colonne, les étiquettes de rôles vont à la ligne.

---

## 5. Comptes

### Objectifs

Permettre de se connecter, depuis les Préférences, aux services qui l'exigent, par identifiant et mot de passe ou par OAuth dans le navigateur. **L'app ne contient aucun code propre à un service ni à OAuth.**

### Sous-tâches

- **PLG-10** : écrire le bloc `account` (état, connexion, déconnexion) et le flux OAuth par `openURL`.

### Comportement utilisateur

- Avec identifiant et mot de passe : l'utilisateur remplit les champs et clique `"Sign In"`. Le bloc affiche ensuite `"Signed in as <nom>"` et un bouton `"Sign Out"`.
- Avec OAuth : l'utilisateur clique `"Sign In…"`, et son navigateur s'ouvre sur la page du service. Après validation, il revient dans l'app : le bloc affiche `"Signed in as <nom>"`.
- Un plug-in peut proposer une identité automatique, comme Soulseek. Le bloc affiche alors un choix `"Automatic identity"` / `"My account"` (voir [[feature-plugin-soulseek]]).

### Règles d'interaction

- `"Sign In"` appelle `account/login` avec les champs saisis. Le plug-in répond `{status: "signedIn", displayName}` ou une erreur lisible.
- Pour OAuth, `account/login` renvoie `{openURL}`. L'app ouvre cette URL dans le navigateur par défaut (`NSWorkspace` sur macOS, `ShellExecute` sur Windows, `xdg-open` sur Linux). Le plug-in reçoit lui-même le retour sur un port local qu'il ouvre (`http://127.0.0.1:<port>/callback`) et termine la requête. L'app attend jusqu'à 5 minutes.
- À l'ouverture des Préférences, l'état affiché vient de `account/status`, seulement si le plug-in tourne déjà ou si `secrets.json` contient un compte. On ne lance pas un processus juste pour dessiner l'onglet : l'état est mis en cache dans `settings.json` (`_accountDisplayName`).
- `"Sign Out"` appelle `account/logout` ; le plug-in efface ses secrets.

### États visuels

- **Déconnecté** : champs vides et `"Sign In"`. Le bouton est désactivé tant qu'un champ obligatoire est vide.
- **Connexion en cours** : champs désactivés, indicateur d'activité, bouton `"Cancel"`.
- **OAuth en attente** : `"Waiting for the browser…"` et `"Cancel"`.
- **Connecté** : `"Signed in as <nom>"` et `"Sign Out"`.
- **Erreur** : message en rouge sous les champs ; les champs restent remplis, sauf le mot de passe.

### Edge cases

- Le navigateur ne s'ouvre pas (Linux sans `xdg-open`) : l'URL est affichée avec un bouton `"Copy Link"`.
- Le port local est déjà pris : le plug-in en essaie un autre ; c'est à lui de le gérer.
- Le jeton expire : le plug-in le renouvelle seul s'il a un jeton de renouvellement. Sinon, il passe à `$/status` `{state: "error", message: "Sign in again"}`, et la carte affiche l'erreur.
- L'iPod est utilisé sur un autre ordinateur : les comptes suivent, puisqu'ils sont sur l'iPod.

---

## 6. Consentement à l'activation

### Objectifs

Un plug-in qui télécharge en pair à pair ou qui lit des pages web non prévues pour ça ne s'active qu'après que l'utilisateur a lu un avertissement clair et l'a accepté. L'accord est demandé une seule fois par type de risque.

### Sous-tâches

- **PLG-11** : afficher l'alerte de consentement à la première activation d'un plug-in dont le manifeste déclare `requiresConsent`, et mémoriser l'accord dans `plugins.json`.

### Comportement utilisateur

- L'utilisateur active Soulseek. Une alerte apparaît, il clique `"Enable"`, et le plug-in s'active.
- Plus tard, il active yt-dlp, qui déclare un autre type de risque (`scraping`). Une alerte apparaît aussi, avec le texte de ce type.
- S'il clique `"Cancel"`, la bascule revient à l'arrêt.

### Règles d'interaction

- Types et textes de l'alerte (titre, puis texte) :
  - `p2p` : `"Enable peer-to-peer sharing?"` / `"<Plug-in> downloads from and shares with other users on a public network. You are responsible for what you download and share, and for following the laws where you live."`
  - `scraping` : `"Enable <Plug-in>?"` / `"<Plug-in> reads data from <service> without an official API. It may stop working at any time, and may go against the service's terms of use."`
- Boutons : `"Enable"` (par défaut) et `"Cancel"`.
- L'accord est mémorisé **par type de risque et par plug-in** dans `plugins.json`.
- Les plug-ins fournis avec l'app sont désactivés au premier lancement. La première fois que l'utilisateur crée un abonnement, une invite propose de les activer, avec les mêmes alertes (voir [[feature-playlist-subscriptions]], section 1).

### États visuels

- Alerte native : NSAlert sur macOS, et le dialogue modal équivalent sur GTK et WinUI.

### Edge cases

- Un plug-in mis à jour ajoute un type de risque : l'alerte est redemandée pour ce type.
- `plugins.json` perdu : tous les consentements sont redemandés.

---

## 7. Paquet `.ippmplugin` et installation

### Objectifs

Distribuer un plug-in sous forme d'un seul fichier qu'on installe par glisser-déposer, comme une extension de navigateur.

### Sous-tâches

- **PLG-12** : définir le format `.ippmplugin` et sa vérification.
- **PLG-13** : écrire l'installation (glisser-déposer et `"Install Plug-in…"`), la mise à jour et la suppression.

### Comportement utilisateur

- L'utilisateur glisse un fichier `.ippmplugin` sur la fenêtre de l'app, ou clique `"Install Plug-in…"` dans l'onglet Plug-ins et choisit le fichier.
- Une fenêtre de confirmation affiche le nom, la version, l'auteur, les rôles et le type de risque. Il clique `"Install"`.
- Le plug-in apparaît dans l'onglet, désactivé, puis il passe par le consentement de la section 6.
- Pour une mise à jour, la confirmation affiche `"Update Soulseek 1.0.0 → 1.1.0"`.
- Pour supprimer : clic droit sur la carte → `"Remove Plug-in…"`, puis une alerte qui demande s'il faut aussi effacer les réglages et les comptes.

### Règles d'interaction

- **Format** : une archive zip renommée **`.ippmplugin`** (décidé le 2026-11-15).
  - À la racine : `plugin.json`, `bin/`, et si besoin `vendor/`, `badge.svg`, `LICENSE`, `README.md`.
  - Un fichier `SHA256SUMS` couvre tous les autres fichiers.
  - La signature des paquets est hors périmètre en v1.
- **Vérifications avant l'installation**, dans l'ordre : zip lisible, `plugin.json` valide, `apiVersion` supportée, exécutable présent pour cet OS, `SHA256SUMS` conforme. Le premier échec arrête tout et s'affiche dans la fenêtre.
- **Installation atomique** : décompression dans `Plug-ins/.<id>.installing/`, puis renommage vers `Plug-ins/<id>/`. Pour une mise à jour, l'ancien dossier est renommé en `.<id>.old`, puis supprimé une fois le renommage réussi. Le plug-in en cours d'exécution reçoit `shutdown` avant le remplacement.
- **macOS** : on retire l'attribut `com.apple.quarantine` des fichiers décompressés et on signe ad hoc les exécutables (`codesign -s -`), comme l'app.
- Une version plus ancienne que celle installée : la confirmation affiche `"Downgrade"` à la place de `"Update"`.
- Les fichiers `.ippmplugin` sont associés à l'app (type de document déclaré dans `Info.plist` sur macOS) **seulement si c'est faisable sans installer quoi que ce soit sur l'hôte**. À confirmer, puisque l'app est portable.

### États visuels

- **Glisser au-dessus de la fenêtre** : contour d'accent autour de la fenêtre, avec le texte `"Install Plug-in"`.
- **Confirmation** : feuille attachée à la fenêtre des Préférences ou à la fenêtre principale.
- **Installation** : barre de progression indéterminée dans la feuille.
- **Échec** : message d'erreur dans la feuille, avec seulement le bouton `"OK"`.

### Edge cases

- Paquet corrompu ou `SHA256SUMS` faux : `"This plug-in is damaged and can't be installed."`
- iPod plein : `"Not enough space on the iPod."`, et rien n'est modifié.
- Un plug-in non empaqueté du même `id` est chargé : l'installation se fait, mais un avertissement indique que le plug-in non empaqueté reste prioritaire.
- Glisser un fichier `.ippmplugin` pendant une synchro d'abonnement qui utilise ce plug-in : on propose d'attendre la fin ou d'annuler la synchro.

---

## 8. Mode développeur

### Objectifs

Permettre à un développeur, ou à un agent, de tester un plug-in directement depuis son dossier de travail, sans l'empaqueter, comme « Charger l'extension non empaquetée » dans Chrome.

### Sous-tâches

- **PLG-14** : ajouter la bascule `"Developer Mode"`, le chargement d'un dossier, le rechargement et le journal en direct.

### Comportement utilisateur

- L'utilisateur active `"Developer Mode"` en bas de l'onglet Plug-ins. Le bouton `"Load Unpacked…"` apparaît.
- Il choisit un dossier qui contient `plugin.json`. Le plug-in apparaît avec un badge `"Unpacked"`.
- Après avoir recompilé son plug-in, il clique `"Reload"` sur la carte.
- Il clique `"Show Log"` pour voir en direct ce que le plug-in écrit (stderr et `$/log`) et les messages JSON-RPC échangés.

### Règles d'interaction

- Le chemin d'un plug-in non empaqueté est mémorisé **pour l'hôte courant** dans `known_hosts.json`, puisque ce dossier n'existe que sur cet ordinateur.
- Un plug-in non empaqueté **prend le pas** sur un plug-in installé de même `id`. La carte du plug-in installé indique `"Overridden by unpacked plug-in"`.
- `"Reload"` : `shutdown` (puis arrêt forcé), nouvelle lecture du manifeste, et nouvelle vérification. Aucune relance tant qu'aucun appel n'arrive.
- `"Remove"` sur un plug-in non empaqueté l'oublie, sans toucher au dossier.
- **Journal** : une fenêtre séparée qui garde les 2 000 dernières lignes en mémoire, et rien sur disque. Boutons `"Clear"` et `"Copy"`. Les messages JSON-RPC n'y sont enregistrés que lorsqu'elle est ouverte, pour éviter tout coût le reste du temps.
- Désactiver `"Developer Mode"` masque les boutons, mais les plug-ins non empaquetés restent chargés. Pour les retirer, il faut les supprimer un par un.

### États visuels

- Badge `"Unpacked"` sur la carte, de la couleur d'accent.
- Journal : texte à chasse fixe, les erreurs en rouge, les messages JSON-RPC en gris.

### Edge cases

- Le dossier n'est pas disponible (disque externe débranché) : carte en état « Error », `"Folder not found"`.
- Le dossier change pendant que le plug-in tourne : pas de rechargement automatique (pas de surveillance du disque) ; l'utilisateur clique `"Reload"`.

---

## 9. Outils CLI et modèle pour les agents

### Objectifs

Qu'un agent puisse créer, vérifier et empaqueter un plug-in en ligne de commande, et qu'il **vérifie seul son travail**. Le plug-in Spotify sert d'exemple de référence pour toutes les sources.

### Sous-tâches

- **PLG-15** : ajouter les commandes `plugin new`, `plugin test`, `plugin pack` et `plugin install` à `ipodpromax`.
- **PLG-16** : écrire le modèle de squelette utilisé par `plugin new`, et la page `Docs/Architecture/Plug-ins.md`. Elle décrit la marche à suivre pour un agent, et reprend l'annexe A.

### Comportement utilisateur (développeur ou agent)

- `ipodpromax plugin new Deezer --role playlistSource` crée `Plug-ins/Deezer/` avec un manifeste, `Sources/`, `Tests/fixtures.json` et un rôle à remplir.
- `ipodpromax plugin test Plug-ins/Deezer` affiche une ligne par vérification (✓ ou ✗) et sort avec le code 0 seulement si tout passe.
- `ipodpromax plugin pack Plug-ins/Deezer` produit `Deezer-1.0.0.ippmplugin`.
- `ipodpromax plugin install Deezer-1.0.0.ippmplugin` installe sur l'iPod courant, ou sur `Build/` si aucun iPod n'est branché.

### Règles d'interaction

- **Vérifications de `plugin test`**, dans l'ordre :
  1. manifeste valide ;
  2. exécutable présent pour l'OS courant ;
  3. `initialize` en moins de 10 s ;
  4. pour chaque rôle déclaré, un appel avec les données de `Tests/fixtures.json` et un contrôle de la forme de la réponse ;
  5. une requête annulée renvoie `cancelled` en moins de 2 s ;
  6. le badge (s'il y en a un) est lisible par `CustomSymbol` ;
  7. `shutdown` propre ;
  8. le processus s'arrête quand stdin se ferme.
- Avec `--offline`, les appels réseau sont remplacés par les réponses enregistrées dans `fixtures.json`, si le plug-in en fournit.
- **Marche à suivre pour un agent qui ajoute une source** :
  1. `plugin new` ;
  2. remplir `fetch(url:)` en s'inspirant de `Plug-ins/Spotify/` ;
  3. déclarer `urlPatterns` et `badge` ;
  4. remplir `fixtures.json` ;
  5. `plugin test` ;
  6. ajouter la cible au `Package.swift` racine et la ligne de build dans `Tools/Build/`.

  **Il ne touche jamais au moteur d'abonnements, aux Préférences ni aux autres plug-ins.** S'il doit le faire, c'est que le contrat est incomplet : on corrige d'abord cette spec.
- Les plug-ins fournis avec l'app sont des cibles du `Package.swift` racine (un seul `Package.swift`), avec leurs sources dans `Plug-ins/<Nom>/` à la racine du dépôt.

### États visuels

- Sortie terminal : `✓`/`✗`, puis un résumé `7/8 checks passed`, en couleur seulement si la sortie est un terminal.

### Edge cases

- `plugin new` avec un nom déjà pris : refus, rien n'est écrasé.
- `plugin test` sur Windows ou Linux pour un plug-in sans exécutable de cet OS : échec à l'étape 2, avec l'OS manquant.

---

## Hors périmètre

- Signature cryptographique des paquets et catalogue de plug-ins en ligne.
- Mise à jour automatique des plug-ins. Les seules mises à jour possibles sont manuelles, par paquet ; yt-dlp a son propre bouton (voir sa spec).
- Plug-ins avec leur propre interface (vues). Un plug-in ne contribue que des réglages déclarés.
- Isolation des plug-ins (sandbox) : un plug-in a les droits de l'utilisateur.

## Questions ouvertes

1. Chiffrer `secrets.json` avec une clé dérivée de l'identifiant de l'iPod ? Cela ne protège que contre une lecture superficielle.
2. Associer l'extension `.ippmplugin` à l'app sur l'hôte, alors que l'app est portable et n'installe rien ?
3. Le consentement doit-il être demandé une fois par plug-in, ou une seule fois par type de risque pour tous les plug-ins ?
4. Faut-il un moyen de désactiver tous les plug-ins d'un coup (mode sans échec), par exemple en maintenant ⌥ au lancement ?

---

## Annexe A : protocole JSON-RPC

| Méthode | Sens | Paramètres → résultat |
| --- | --- | --- |
| `initialize` | app → plug-in | `{apiVersion, host:{os, arch, appVersion, onIPod}, paths:{data, cache, temp, ffmpeg}, settings, config}` → `{roles, version}` |
| `shutdown` | app → plug-in | → `{}` |
| `settings/changed` | notification app → plug-in | `{settings}` |
| `account/login` | app → plug-in | `{key, fields}` → `{status, displayName}` ou `{openURL}` (OAuth ; la réponse finale arrive par `account/status` en notification) |
| `account/logout`, `account/status` | app → plug-in | → `{status, displayName?}` |
| `action/<key>` | app → plug-in | → `{message?}` |
| `source/fetch` | app → plug-in | `{url}` → `{playlist: Playlist, tracks: [TrackRef]}` |
| `resolver/search` | app → plug-in | `{track: TrackRef, policy}` → `{candidates}` (liste finale) ; résultats partiels par la notification `resolver/candidates` `{requestID, candidates}` |
| `downloader/download` | app → plug-in | `{candidate, destinationDir}` → `{path}` |
| `share/setIndex` | app → plug-in | `{part, lastPart, entries:[{virtualPath, realPath, size, bitrateKbps?, durationMs?}], uploadSlots}` → `{}` |
| `share/stop` | app → plug-in | → `{}` |
| `$/cancelRequest` | notification app → plug-in | `{id}` |
| `$/progress` | notification plug-in → app | `{requestID, done, total?, message?}` |
| `$/log` | notification plug-in → app | `{level: "debug"/"info"/"warning"/"error", message}` |
| `$/status` | notification plug-in → app | `{state: "connecting"/"ready"/"error", message?}` |

Codes d'erreur (`error.data.code`) : `cancelled`, `notFound`, `unauthorized`, `rateLimited` (avec `retryAfterSeconds`), `network`, `apiChanged`, `unsupported`, `wrongResolver`, `internal`. Le texte `error.message` est en anglais et peut être montré tel quel à l'utilisateur.

`share/setIndex` est découpé en morceaux d'au plus 5 000 entrées (`part` et `lastPart`).

## Annexe B : manifeste `plugin.json`

```json
{
  "id": "soulseek",
  "name": "Soulseek",
  "version": "1.0.0",
  "apiVersion": 1,
  "description": "Search, download and share on the Soulseek network.",
  "author": "iPod Pro Max",
  "license": "MIT",
  "roles": ["resolver", "downloader", "share"],
  "executable": {
    "macos": "bin/macos/soulseek-plugin",
    "windows-x64": "bin/windows-x64/soulseek-plugin.exe",
    "windows-arm64": "bin/windows-arm64/soulseek-plugin.exe",
    "linux-x86_64": "bin/linux-x86_64/soulseek-plugin",
    "linux-aarch64": "bin/linux-aarch64/soulseek-plugin"
  },
  "urlPatterns": [],
  "badge": "badge.svg",
  "requiresConsent": "p2p",
  "settings": [
    {"key": "share", "type": "bool", "label": "Share my music", "default": true}
  ],
  "config": {}
}
```

- `id` : minuscules, chiffres et tirets ; c'est aussi le nom du dossier.
- `urlPatterns` (rôle `playlistSource`) : expressions régulières testées sur l'URL collée. L'app choisit la source **sans lancer de processus**.
- `badge` (facultatif) : SVG monochrome **à un seul tracé**, avec les commandes M, L, C et Z que lit déjà `CustomSymbol` (`UI/CustomSymbols.swift`), dans une boîte carrée. Il sert dans l'icône des playlists d'abonnement et dans la fenêtre `"New Subscription"`. Il est lu sans lancer le plug-in. Un SVG plus complexe est refusé, avec un message en mode développeur.
- `config` : bloc libre transmis tel quel dans `initialize`, pour les données qu'on veut corriger sans recompiler (par exemple les hash pathfinder de Spotify).
- `requiresConsent` : `"p2p"`, `"scraping"`, ou absent.

## Annexe C : exécutables par OS

- **macOS** : binaire universel (arm64 et x86_64), signé ad hoc.
- **Linux** : binaire statique (musl), comme la CLI.
- **Windows** : un exécutable Swift a besoin des DLL du runtime Swift. Pour ne pas les copier dans chaque plug-in, l'app **lance le plug-in avec le dossier de ses propres DLL en tête du `PATH`** du processus enfant. Un plug-in tiers écrit dans un autre langage n'est pas concerné.
- `PluginMain` s'arrête quand stdin se ferme, sur les 3 OS. C'est la seule garantie contre les processus orphelins.
