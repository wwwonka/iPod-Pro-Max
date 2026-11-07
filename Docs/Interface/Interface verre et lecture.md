# Interface verre et lecture

## Composition

L’interface sépare la barre de médias, la navigation musicale et le contenu. Les pages iPod, podcasts, livres et photos restent accessibles. La musique propose Ajouts récents, Toutes les chansons, Artistes, Albums et Playlists. Les albums sont regroupés par artiste d’album et titre ; leurs identifiants évitent les collisions entre artistes.

Le lecteur flotte au bas de la fenêtre après le premier lancement de piste et reste présent pendant la navigation. Sa fermeture arrête le moteur, annule l’analyse de waveform et libère la file. La fenêtre suit le thème système. Sur Mac, `NSVisualEffectView` fournit le verre sans API propre à Tahoe ; Windows utilise son fond Acrylic existant et GTK son intégration de transparence existante, avec un fond lisible lorsqu’un flou natif n’est pas disponible.

Les SF Symbols restent natifs sur Mac. Linux et Windows utilisent uniquement la police SF installée localement ; elle n’est pas distribuée. Les nouveaux glyphes sont identifiés avec `Tools/Build/match-glyph.swift`. Des libellés remplacent les glyphes si la police ou un symbole manque.

## Modèle de lecture

`MediaKit.PlaybackQueue` conserve une copie de l’ordre réellement affiché au lancement, y compris le tri de la table et le filtre de la page artiste. Les changements ultérieurs de vue ou de recherche ne modifient pas la file. L’aléatoire conserve la piste en cours, visite chaque identifiant une seule fois et permet de retrouver l’ordre initial lorsqu’on le désactive.

La répétition a trois modes : désactivée, file complète et piste seule. Une commande Suivant ignore la répétition de piste ; celle-ci s’applique à la fin automatique du morceau. Précédent repart au début après trois secondes, sinon rejoint la piste précédente. À la fin d’une file sans répétition, la lecture s’arrête.

`PlaybackController` possède l’état et reçoit les événements d’un `AudioEngine` natif : AVPlayer sur Mac, Windows MediaPlayer sur Windows, GStreamer playbin sur Linux. Le moteur n’est créé qu’à la première lecture. Les tests peuvent injecter un moteur simulé. Le contrôleur ne publie aucune modification de la bibliothèque.

Les erreurs de décodage ou d’accès arrêtent le lecteur et affichent un message. Une nouvelle tentative est possible avec Lecture. Volume, aléatoire et répétition restent des réglages de session ; aucune nouvelle donnée persistante n’est ajoutée.

## Travail et animations

- Les tables conservent leurs contrôles natifs virtualisés. Seules les cellules visibles demandent leurs pochettes ; le cache de vignettes partage les décodages concurrents et borne la mémoire.
- Les grilles d’albums utilisent NSCollectionView, GtkGridView et, dans la projection WinUI actuelle sans GridView, une ListView de rangées de tuiles virtualisées.
- Sur Mac, la disposition finale du panneau est appliquée une fois puis Core Animation translate les couches. Une image temporaire du panneau sortant est libérée après la transition. Une nouvelle commande inverse la transition.
- Windows utilise la transition native de SplitView et une translation de contenu par Storyboard. GTK utilise son horloge de rendu et translate des allocations natives ; la position du séparateur ne change qu’une fois par transition.
- Les transitions de panneau durent environ 200 ms. La réduction des animations du système est respectée.
- La progression Mac vient de l’observateur AVPlayer. Windows utilise DispatcherQueueTimer et Linux une horloge de lecture à 250 ms. Ces horloges sont arrêtées en pause et lorsque la fenêtre est masquée ; aucun timer de lecture ne tourne au repos.
- Les waveforms sont analysées hors du fil principal et mises en cache selon le chemin, la taille et la date du fichier. La quantité de pics et la mémoire des caches sont bornées. AVAssetReader est utilisé sur Mac, ffmpeg ailleurs. L’annulation est synchronisée avec le lancement de ffmpeg pour éviter un décodeur orphelin après un changement rapide de piste.

Les builds Linux installent les en-têtes GStreamer et les plugins base/good/libav. Les distributions Linux qui exécutent l’app doivent aussi fournir ces bibliothèques, comme elles fournissent GTK.

## Mesures du 5 novembre 2026

Bibliothèque de référence : 5 299 pistes. MacBook Pro Apple M1 Max, macOS 15.7.1 ; compilation de développement. Les nombres ci-dessous mesurent la disposition sur le fil principal, pas une fréquence d’affichage.

| Scénario | Avant | Après |
|---|---|---|
| Panneau, travail pendant la transition | 4–5 dispositions en 167–189 ms | Une disposition finale puis composition native pendant 200 ms |
| Coût de disposition du panneau | 27–33 ms par image, pointe à 49 ms dans le relevé initial | 26–35 ms au total dans le relevé final avant la dernière correction de grille |
| Travail de disposition par image d’animation | Recalcul du split et des vues | Aucun rappel de disposition SwiftCrossUI par image sur Mac/Windows |
| Retour vers les chansons, médiane de 8 passages | 50 ms (maximum 164 ms) | 46 ms (maximum 106 ms) |

Une tentative d’enregistrement Instruments « Animation Hitches » a produit une trace, mais ses tables d’images rendues et d’accrocs sont vides. Cela ne certifie ni zéro image perdue ni une tenue à 120 Hz. Le premier calcul de disposition dépasse encore un budget de 16,7 ms ; les chiffres prouvent surtout la suppression du recalcul à chaque image de transition. Une mesure de présentation sur écran réel à 60/120 Hz reste distincte des mesures de VM et de ces coûts CPU.

## Vérification reproductible

- `swift test` : file vide, limites, déduplication, ordre, aléatoire, répétition et tests existants des modules partagés.
- `IPPM_CHECK_INTERACTIONS=1 .build/debug/iPodProMaxApp` : moteur simulé, création réelle des tuiles avec le même chemin que l’écran Albums, sélection multiple, dépôt, vues masquées, éjection et caches.
- `IPPM_CHECK_AUDIO=/chemin/vers/un-court-fichier.wav <application>` : décodage et sortie réels, progression, pause, seek, fin et erreur de fichier manquant. Utiliser un court WAV silencieux pour éviter de jouer de la musique pendant les tests. `IPPM_LOG=<fichier>` permet de récupérer le résultat d’un lancement sans console, notamment sous Windows.
- `IPPM_BENCH=2 .build/debug/iPodProMaxApp` : navigation et transitions sur la bibliothèque de référence ; `--library <fichier>` fixe explicitement la source.
- `IPPM_PREVIEW_LIBRARY=1` : aperçu sans écriture dans la bibliothèque portable ; `IPPM_LIBRARY` sélectionne la bibliothèque et `IPPM_PREVIEW_ARTWORK` son dossier de pochettes.

Les essais audio réels ont passé sur Mac, Fedora ARM64 et Windows 11 ARM64. Les builds Linux x86-64/ARM64 et Windows ARM64 sont vérifiés séparément des essais macOS. Dans Windows, exécuter le binaire depuis le disque local de la VM : le lancement depuis le partage UNC Mac peut planter Foundation avant même la création de la fenêtre.

Aucun nouveau moteur de synchronisation iPod ni récupération de paroles n’est ajouté par cette refonte.

## Voir aussi

- [[Rail de médias macOS]] : comportement détaillé du rail (états, noms de sections, extras épinglables, recherche repliable).
