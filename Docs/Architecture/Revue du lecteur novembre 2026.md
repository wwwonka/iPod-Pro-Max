# Revue du lecteur novembre 2026

> Photographie de la revue initiale. Les mécanismes appliqués ensuite et leurs mesures sont décrits dans [[Corrections de revue du lecteur]]. Les constats ci-dessous restent rattachés au commit audité.

Audit du 20 novembre 2026 sur `4d93b08954792fe89f30ae2ad6327de842a2d610`, couvrant les huit commits depuis `2814bd2` inclus : 59 fichiers, environ 5 400 lignes ajoutées. Le périmètre est le lecteur PLR1–19 et ses branchements à la bibliothèque, au cache, aux préférences et à la fenêtre macOS. Les autres sous-systèmes ne font pas l’objet d’un audit exhaustif.

La séparation entre modèles portables, moteur, analyse utility et dessin natif est utile et les scénarios courants sont couverts. Aucun défaut de gravité P0/P1 n’a été confirmé dans ce périmètre. Six défauts fonctionnels ou de robustesse P2 et une information obsolète P3 sont décrits ci-dessous. Une partie est reproduite par sonde ; les autres constats reposent sur les transitions explicites du code. Cette revue documente les corrections à envisager sans les appliquer au produit.

## Constats

### R1 P2 Échap n’annule pas tout le geste de scrub

Source : `iPod Pro Max/UI/PlayerLCDContentMac.swift:553–566`, `LCDPlaybackPlot.keyDown` et `propose`.

Après un appui dans la timeline, Échap efface la proposition, mais ne met pas `gestureCancelled` à vrai. Un mouvement supplémentaire avec le bouton encore tenu appelle `propose`, qui redémarre immédiatement un nouveau scrub. Le relâchement effectue alors un seek malgré l’annulation demandée. Le même état permet à un geste horizontal déjà engagé de reprendre après Échap.

Sonde exécutée sur le corps exact de `LCDPlaybackPlot`, avec contrôleur et horloge simulés : position initiale 10 s, appui à 30 %, Échap, glissement vers 60 %, relâchement. Sortie : `After Escape, proposal: nil`, puis `After continued drag and release, seeks: [60.0]`. Il ne s’agit pas d’une simulation du dessin ou du comportement d’AVPlayer : la sonde isole la décision de seek.

Correction à prévoir : verrouiller le geste annulé jusqu’au prochain mouseDown ou début de défilement, puis tester qu’aucun seek n’est émis entre Échap et le relâchement.

### R2 P2 Le réordonnancement perd les autres pistes d’une sélection multiple

Source : `iPod Pro Max/UI/PlayerQueueMac.swift:104–122`.

La table autorise la sélection multiple et conserve tous les identifiants dans `draggedIDs`. Elle écrit un item de presse-papiers par ligne, mais `acceptDrop` ne lit que `string(forType:)` et appelle `moveInQueue` une seule fois. Déplacer deux lignes ne déplace donc que la première ; la seconde reste à son ancien endroit, contrairement au groupe visible pendant le drag.

Une sonde AppKit sur un presse-papiers privé avec deux items `b` et `c` confirme : les items sont `["b", "c"]`, tandis que le chemin consommé par `acceptDrop` donne seulement `b`. Le parcours de dépôt complet avec souris physique n’a pas été exécuté pendant cette revue.

Correction à prévoir : décoder les items dans l’ordre et effectuer une insertion groupée via la file. Inclure des sélections contiguës et disjointes, un déplacement vers le haut et vers le bas, et la protection de la piste courante.

### R3 P2 Les échecs de transition plein écran ne réconcilient pas le chrome

Sources : `iPod Pro Max/UI/WindowChromeMac.swift:459–480` et `iPod Pro Max/UI/MacWindowLifecycle.swift:97–120`.

`willEnterFullScreen` masque les boutons système. Si l’entrée échoue, `windowDidFailToEnterFullScreen` restaure le style `.titled`, mais ne rétablit pas `hidingTrafficLights`. Les passes de disposition suivantes peuvent donc conserver les boutons masqués dans une fenêtre normale. Symétriquement, `willExitFullScreen` remet immédiatement la géométrie fenêtre ; l’échec de sortie ne remet que le style, sans réactiver la géométrie plein écran ni ses états de révélation.

C’est un défaut identifié dans les chemins d’échec, pas une panne AppKit provoquée pendant la revue. L’aller-retour réussi est déjà couvert par l’intégration native ; il ne teste pas ces deux callbacks.

Correction à prévoir : une réconciliation centrale du chrome à partir du style final de la fenêtre, appelée aussi dans les deux callbacks d’échec. Vérifier les boutons, la transparence, le retrait et les observations du titre auxiliaire.

### R4 P2 Un deuxième lancement peut supprimer un Scratch encore utilisé

Source : `Sources/MediaKit/TemporaryMediaCache.swift:84–96` ; utilisateurs concernés : `MacAudioAnalysis`, `TagWriter` et `FFmpegTranscoder.posterFrame`.

Le dossier est partagé entre instances pour une même racine temporaire. Le nettoyage de lancement considère tout Scratch créé avant son propre lancement comme abandonné. Il n’existe ni propriétaire de fichier ni verrou interprocessus ; le verrou récursif protège uniquement un objet cache. Lancer un autre build pendant une analyse ou une opération utilisant Scratch peut supprimer un fichier encore actif.

Sonde exécutée sur les sources exactes du cache et de SHA1 : une première instance crée un fichier et garde son FileHandle ouvert ; une seconde instance sur la même racine exécute le nettoyage de lancement. Le fichier n’existe plus et le commit de la première instance échoue : `First instance scratch survives second launch: false`, `First instance analysis committed: false`. Le décalage d’une seconde de l’heure de lancement rend l’ordre reproductible sans attente.

Pour une analyse, le résultat en mémoire peut rester disponible mais ne sera pas persisté. Pour un outil consommant un chemin Scratch, l’entrée peut manquer. Aucune perte de fichier musical original n’a été reproduite.

Correction à prévoir : isoler les fichiers de travail par session/processus et ne nettoyer les anciennes sessions qu’après vérification de leur abandon ; conserver le partage éventuel des seuls résultats dérivés avec un protocole adapté.

### R5 P2 Une fenêtre auxiliaire peut réactiver la progression du lecteur masqué

Sources : `iPod Pro Max/Platforms/AudioEngine.swift:34–39,89–97` et `iPod Pro Max/UI/PlayerLCDContentMac.swift:104–108`.

La visibilité du lecteur a deux propriétaires. Le LCD transmet la visibilité de sa propre fenêtre, tandis que le moteur la remplace sur les notifications par la présence de n’importe quelle fenêtre visible de l’application. Pendant une lecture avec fenêtre principale masquée et Préférences visibles, ce second chemin peut remettre `visible=true` et réinstaller l’observateur de progression à 250 ms. L’état « lecteur invisible » ne suffit donc pas à garantir l’arrêt de cette horloge.

Le conflit est explicite dans le code ; son coût CPU n’a pas été mesuré avec une fenêtre auxiliaire pendant cette revue. Les relevés historiques de fenêtre masquée ne précisent pas ce scénario.

Correction à prévoir : donner au moteur une seule source de visibilité, liée à la surface du lecteur, et vérifier qu’une notification de Préférences ou de popover ne recrée pas l’observateur.

### R6 P2 Le harnais de hover transforme une perte de focus en crash de contrôle

Source : `iPod Pro Max/UI/ToolbarPlayerMac.swift:610–648`, `checkHoverFeedback`.

La sonde crée sa fenêtre, attend puis impose par `precondition` l’apparition d’un hover ou d’une ombre active. Pourtant les chemins de survol refusent justement ces effets si la fenêtre perd le statut key. Le harnais ne vérifie pas que cette condition est restée vraie pendant ses attentes. Les derniers essais ont échoué à `Delayed native hover plate` et à `Elevation base: key=false, enabled=true, shadow=0.12, plate=0.0`. Cette seconde valeur est cohérente avec l’état inactif du bouton.

Ce résultat ne prouve pas un crash du lecteur ordinaire : il se produit dans le chemin opt-in de vérification. Il empêche en revanche d’utiliser un échec de ce test comme preuve fiable de régression du hover pendant que le propriétaire travaille dans une autre application.

Correction à prévoir : contrôler la précondition d’activation, attendre une activation stable avec une borne, et signaler un contrôle non exécutable si le focus est repris. Les assertions d’apparence doivent rester strictes quand leurs préconditions sont remplies ; aucun retour silencieux ne doit être compté comme succès.

### R7 P3 L’espace libre de l’idle reste celui de la première lecture du périphérique

Source : `iPod Pro Max/Library/PlayerDisplayController.swift:44–55`, appelé par `App.swift:90`.

Le contrôleur ne relit les statistiques que si l’identifiant du périphérique change. Après une synchronisation ou une suppression, le même iPod conserve son identifiant : les appels suivants retournent avant `volumeStats()`, et le LCD peut garder une ancienne valeur d’espace libre jusqu’au changement de périphérique ou au redémarrage.

Constat statique ; aucune synchronisation sur matériel physique n’a été effectuée. Correction à prévoir : invalider la valeur sur les événements de modification/fin d’opération déjà disponibles, en gardant la lecture des statistiques hors du fil principal et sans polling.

## Risques et points à confirmer

- **Titre auxiliaire plein écran.** Le fallback recherche le nom d’exécution `NSToolbarFullScreenWindow` et observe ses propriétés. Son absence ou une évolution de sa hiérarchie peut rendre la suppression de bande inopérante. Les validations actuelles couvrent la machine de développement, pas toutes les versions de macOS ni plusieurs écrans.
- **Popover de volume pendant le redimensionnement.** Le slider n’est pas replacé tant que le popover est ouvert et aucun delegate de fermeture ne déclenche explicitement sa réinstallation. Vérifier si le popover peut rester ouvert pendant une transition vers une largeur non compacte ; son comportement natif de fermeture détermine si le défaut est observable.
- **Annulation d’un drag hors de la file.** Le chemin de fin supprime les pistes lorsque l’opération est vide et que le pointeur est hors de la fenêtre. Vérifier le cas Échap pendant un drag extérieur pour distinguer annulation et retrait volontaire.
- **Callbacks uniques du LCD.** Chaque `PlayerLCDContent` remplace `PlayerDisplayController.shared.onChange`. Le contrôle `ToolbarPlayerMac.checkInteractions` crée un contenu temporaire qui peut écraser le callback du contenu vivant ; le test n’est pas isolé du singleton d’affichage. Une subscription annulable éviterait cette contamination et faciliterait des fenêtres multiples.
- **Compatibilité de concurrence Swift 6.** Les builds précédents signalent des valeurs par défaut `.shared` isolées au MainActor dans des initialiseurs. La compilation actuelle du package n’en fait pas une erreur. Une migration de mode de langage mérite une passe dédiée.
- **Portage et matériel.** Cette revue ne valide ni le rendu Windows/Linux, ni les gestes AirPods/Bluetooth, ni les touches média physiques. Ils ne peuvent pas être déduits du succès des tests des modèles.

## Vérifications et limites des preuves

| Vérification | Résultat et portée |
|---|---|
| `swift build --product iPodProMaxApp` | Réussi, 4,76 s en incrémental ; pas une mesure de compilation à froid |
| `swift test` | 89 tests, 0 échec, 5 ignorés, 15,07 s ; les cinq ignorés nécessitent FFmpeg non disponible dans ce lancement |
| Sonde du scrub | Reproduction du seek après Échap sur le corps exact de la classe et un contrôleur simulé |
| Sonde du presse-papiers | Deux items présents, un seul identifiant lu par le chemin utilisé au dépôt |
| Sonde Scratch | Reproduction de la suppression d’un fichier actif et de l’échec de commit entre deux instances de cache |
| Intégrations clair/sombre du dernier changement | Journaux antérieurs du même HEAD : géométrie 820–1 600 pt, recherche, lecture, Dock et plein écran réussis ; pas relancés pour cette revue documentaire |
| Test séparé de hover | Échecs de focus précédents analysés ; aucune conclusion de régression produit tirée de ces préconditions |

Les sondes ont été compilées dans `/tmp` à partir des sources locales, sans modifier le produit. Leurs dépendances UI/moteur non concernées étaient simulées pour le scrub ; le presse-papiers était privé et le cache utilisait une racine temporaire dédiée, effacée ensuite. Ces sondes ne remplacent pas un test de gestes physiques. Aucun nouveau benchmark d’import, d’analyse ou de consommation CPU n’a été exécuté : le produit n’est pas modifié par cette revue et les mesures historiques gardent leurs conditions d’origine.

## Documentation associée

- [[Lecteur et session média]] : responsabilités, correspondance PLR1–19, données, horloges et protocole de contrôle.
- [[LCD du lecteur]] : état visuel courant et mesures historiques qualifiées.
- [Spec initiale](../_Specs/feature-toolbar-player.md) : brief de départ, à lire avec les choix visuels ultérieurs documentés.

La priorité technique proposée est l’annulation du scrub, le déplacement groupé, la réconciliation des transitions et la propriété des fichiers Scratch, puis la visibilité de l’horloge et la fiabilité du harnais. L’actualisation de l’espace libre peut suivre. Le suivi des corrections appartient au GitHub Project ; ce rapport conserve les constats au commit audité.
