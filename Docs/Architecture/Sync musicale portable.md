# Sync musicale portable

Décision : [[ADR-006 Application entièrement portable]].

## Parcours

Le bouton + choisit le dossier musical de l'ordinateur courant; la flèche circulaire relance le scan. Les tables natives autorisent la sélection étendue (Cmd/Ctrl, Maj, tout sélectionner). Un dépôt sur une ligne iPod transmet des identifiants de pistes à une file d'ajout par appareil, ciblée par son identité stable, même si deux iPods portent le même nom.

Le moteur utilise `SyncOptions.additiveOnly`. Il conserve les pistes non sélectionnées, les playlists (y compris leurs règles intelligentes) et les anciennes entrées ArtworkDB/ithmb. Une annulation ou une erreur avant publication de la base nettoie les nouveaux fichiers audio non référencés. Le mode existant de la CLI est inchangé.

`manifest.json` enregistre l'intention avant la copie avec des dbid réservés, afin de reprendre après une interruption entre publication de la base et publication du manifeste. L'empreinte complète SHA-1 + taille identifie les fichiers strictement identiques entre hôtes; elle ne compare pas la similarité musicale. Une piste modifiée devient un nouvel ajout. Les références vers une copie déjà présente ne changent pas son propriétaire.

## Stockage et réactivité

- `known_hosts.json` : identités dérivées de l'OS, noms et sources par catégorie.
- `Hosts/<id>/library.json` : index local à l'hôte mais stocké sur l'iPod, avec racines précédentes pour la relocalisation.
- `Hosts/<id>/Artwork/` et `Transcodes/` : tous les caches sur l'iPod.
- `settings.json` : mode de vue et choix des pochettes communs aux trois interfaces.

Une source inaccessible retire ses pistes du cache; le dossier reste configuré. Les fichiers inchangés réutilisent leurs tags. Les scans et empreintes utilisent une fenêtre parallèle adaptée aux cœurs disponibles. Les mutations observables sont regroupées; aucune surveillance périodique au repos.

Les registres d'identité/propriété endommagés utilisent `.bak`; si les deux copies sont illisibles, on signale l'erreur sans les remplacer par un registre vide. Les écritures passent par `DeviceDataFolder`/`FileOps`.

## Validation reproductible

```sh
swift test
Tools/PortableCheck/run.sh '<music-folder>' '<nouveau-dossier-ipod-de-test>'
```

Le contrôle portable lit les fichiers originaux, crée uniquement un nouvel iPod simulé, mesure les trois chargements puis transfère deux pistes, dont une nécessitant une conversion lorsqu’il y en a dans la source. Il teste le même point d'entrée privé que les dépôts, refuse du texte externe et une cible inconnue, puis vérifie qu'un second dépôt ne duplique rien.

Mesures initiales sur le Mac de développement, 2026-10-31, 5 299 pistes, iPod simulé sur SSD : premier scan **9,600 s**, chargement du cache + contrôle d'accessibilité **0,122 s**, scan incrémental **0,995 s**. Ces chiffres ne mesurent pas le disque dur d'un iPod physique.

Le contrôle a également réussi avec un MP3 et un FLAC réel, converti en AAC sur l’iPod simulé. Les caches de la CLI sont eux aussi placés dans `Hosts/<id>/CLI Cache/`, sans cache local.

Les tests couvrent aussi les fichiers manquants, la reprise après commit interrompu, la déduplication inter-hôtes, les sauvegardes, les hôtes séparés et la préservation des anciennes pochettes et playlists.

Le geste natif a été raccordé sur les trois OS; la sélection multiple est vérifiée visuellement sur macOS. L'outil d'automatisation termine le déplacement à son point de départ (diagnostic AppKit), ce qui empêche de certifier le dépôt physique avec cet outil. Le contrôle logiciel du point d'entrée de dépôt ne remplace pas cet essai manuel.

## Détection de l'iPod connecté

La recherche macOS remonte désormais les nœuds USB même lorsqu'un nœud de stockage intermédiaire possède des IDs vendeur/produit sans numéro de série. Sur l'appareil connecté pendant la validation, la sonde en lecture seule récupère ainsi le GUID et annonce hash58 avec support expérimental. Aucun transfert de test n'a été effectué sur l'iPod physique.

## Navigation entre iPods

`DevicePageCache` conserve un résumé et les options par appareil pendant sa connexion. Le préchargement et la page partagent une seule lecture détachée; un résultat invalidé ne peut pas remplacer un résumé plus récent. La synchronisation et l'actualisation invalident seulement l'appareil concerné; le renommage met à jour son nom en mémoire, et la déconnexion libère son cache.

La page native est réutilisée lors du passage direct entre deux appareils. Ses options sont rechargées depuis la mémoire et les sauvegardes différées appartiennent au cache, afin de survivre à la navigation. L'éjection attend leur écriture. Aucun timer de rafraîchissement ne tourne au repos.

`Tools/DevicePageCheck/run.sh '<ipod-simulé-existant>'` vérifie les accès répétés et la sauvegarde des options. Le mode interne `IPPM_BENCH_DEVICES=1` mesure la navigation native; `IPPM_BENCH_DEVICE_FOLDER` peut ajouter un second appareil simulé au banc de mesure.

Mesure native macOS release du 2026-10-31 : **30 changements, médiane 180 ms, maximum 212 ms, zéro lecture supplémentaire**, entre un iPod physique et deux appareils simulés, pendant les compilations finales. Le contrôle du cache seul effectue 200 accès en 0,206 ms; ce dernier chiffre exclut la mise en page native.

### Dépôts multiples et état de transfert

Sur AppKit, la cible lit chaque `NSPasteboardItem` : la chaîne globale peut concaténer les nonces de plusieurs lignes et ne correspond alors plus au jeton privé. Les listes d'artistes natives utilisent l'index `rowsByArtist` déjà en mémoire pour déposer toutes les pistes de l'artiste, sans rescanner les fichiers.

Le dernier résumé de capacité reste affichable pendant son actualisation. Un transfert sans nouvel ajout ne l'invalide pas. Les lectures répétées du cache et le maintien de l'ancien résumé lors d'une invalidation sont vérifiés par `DevicePageCheck` (deux appareils simulés possibles avec `--extra-ipod`).

Les lignes sélectionnées gardent un fond gris, même avec le focus. Le pictogramme d'éjection mesure 10 points dans une cible de 20 points. Pendant toute la préparation, la copie et la publication du manifeste, il est remplacé par une flèche circulaire qui tourne dans le sens horaire. AppKit utilise `arrow.trianglehead.2.clockwise` avec repli pour les systèmes plus anciens; les autres interfaces utilisent leur glyphe disponible. L'animation native s'arrête quand la file est vide. L'éjection de la page est également désactivée; une réservation interdit qu'une nouvelle copie démarre pendant une éjection déjà engagée.

Le contrôle interne macOS `IPPM_CHECK_INTERACTIONS=1 <exécutable>` prépare un vrai presse-papiers AppKit privé de trois pistes et un dépôt d'artiste, vérifie les identifiants reçus, refuse un jeton externe et contrôle l'animation ainsi que le refus d'éjection pendant l'activité. Aucun fichier musical n'est écrit par ce contrôle. Le contrôle de transfert simulé vérifie aussi les transitions d'activité, l'exclusion copie/éjection et l'absence d'invalidation pour un dépôt déjà synchronisé.

La sélection de navigation reste neutre, mais `isTargetForDropOperation` active la couleur d’accent et le contraste du texte sur la ligne iPod visée. La flèche animée utilise un calque propre, ancré à `(0.5, 0.5)` et positionné au centre de sa zone carrée; la transformation ne touche pas le calque de vue géré par AppKit. Son image est préparée lors d’un changement de symbole ou de teinte, jamais à chaque image d’animation. Le contrôle natif vérifie le pixel de surbrillance contre une référence accent et le centre du calque avant/après redimensionnement.
