# Corrections de revue du lecteur

Correctifs du 20 novembre 2026 à la suite de [[Revue du lecteur novembre 2026]]. Ce document décrit les mécanismes retenus et les vérifications ; le rapport initial reste une photographie du commit `4d93b08`.

## Corrections fonctionnelles

| Constat | Mécanisme actuel | Vérification |
|---|---|---|
| R1 Annulation du scrub | Échap verrouille le geste jusqu’au prochain appui ou début de défilement. Effacer la proposition ne suffit plus à autoriser sa recréation. | Appui, Échap, déplacement et relâchement : aucun seek ; un nouvel appui peut chercher. |
| R2 Drag multiple | Le popover lit tous les items du presse-papiers et appelle une mutation groupée de `PlaybackQueue`. Les identifiants inconnus sont ignorés, la piste courante reste protégée. | Sélections contiguës/disjointes, déplacements haut/bas, ordre du groupe et dépôt natif multi-item. |
| R3 Échec du plein écran | Une même réconciliation règle la géométrie, les boutons système et le titre auxiliaire, aussi bien après réussite que depuis les deux callbacks d’échec. | Contrôle des états finaux fenêtre/plein écran et aller-retour réel par les boutons natifs. La panne AppKit elle-même n’est pas provoquée. |
| R4 Scratch actif | Chaque instance utilise `Scratch/<pid>-<uuid>/`. Le nettoyage ne retire que les sessions d’un processus dont la fin est confirmée. | Deux caches simultanés : le fichier ouvert survit au nettoyage de l’autre, puis son commit réussit ; une session de PID absent est retirée. |
| R5 Visibilité | Seul le LCD transmet la visibilité de sa fenêtre au moteur. Les notifications d’autres fenêtres ne peuvent plus réinstaller son observateur. | Fenêtre principale cachée et fenêtre auxiliaire visible : observateur de progression arrêté, lecture conservée. |
| R6 Focus du harnais | Le contrôle de hover exige une activation stable et retourne un résultat indisponible avec code de sortie 2 s’il perd le focus. Le contrôle du volume vérifie séparément les attentes actives/inactives. | Un test inactif ne compte pas comme validation du hover actif et ne provoque plus cette précondition en échec. |
| R7 Espace libre | L’invalidation des données d’un périphérique invalide aussi l’idle. La lecture reste utility, avec génération pour rejeter un résultat ancien. | Même ID, nouvelle valeur après invalidation ; aucun nouveau relevé lors d’un rendu ou d’un événement pour un autre périphérique. |

Un drag de file mémorise Échap pendant la session et ne retire pas les pistes si le drag est annulé à l’extérieur. Un véritable retrait extérieur ou une opération `.delete` garde le comportement de suppression. Le contrôle natif vérifie ces décisions sans gestes physiques.

La fermeture du popover de volume remet explicitement le slider dans son parent inline si la largeur le permet. Un redimensionnement pendant son ouverture ne dépend plus d’un hypothétique rafraîchissement futur pour le réinstaller.

Le total et le bouton de vidage des préférences portent uniquement sur Spectrum et Waveforms. Les fichiers de travail protégés ne laissent donc pas un total non nul que le bouton ne pourrait pas effacer.

## Propriété des vues et des événements

`PlayerDisplayController.didChange` est un publisher avec subscriptions annulables. Une vue temporaire de contrôle ne peut plus remplacer le callback du LCD vivant. Le rafraîchissement manuel redondant de `ToolbarPlayerMac` a été retiré : le contenu reçoit les changements de présentation par une seule voie.

Le LCD ne traite que les notifications de visibilité de sa propre fenêtre. Le moteur ne parcourt plus `NSApp.windows` pour décider de sa visibilité. Une pause arrête son observateur de temps ; le spectre termine sa courte extinction puis arrête aussi son display link. Le contrôle d’intégration attend et vérifie l’arrêt des deux horloges, puis relance la lecture.

Le fallback du titre auxiliaire ne dépend plus du nom d’une classe d’implémentation d’AppKit. Il cherche une unique surface mince de même largeur et au même bord supérieur que la fenêtre principale, sur son écran. En cas d’ambiguïté, il préserve les autres fenêtres. Le header peut aussi révéler directement ses propres boutons système au survol, même sans surface auxiliaire détectée. Cette stratégie reste à valider sur d’autres versions de macOS et des configurations multi-écrans.

Les timers d’appui maintenu appartiennent au bouton. Perdre l’activation annule le délai et la répétition ; ils sont invalidés à la fin du suivi. Les moniteurs clavier temporaires sont retirés avec leur propriétaire. Les appels de verrouillage du display link restent dans de courtes fonctions synchrones, sans verrou conservé au travers d’un `await`.

## Carte du code pour la reprise

| Fichier | Responsabilité |
|---|---|
| `ToolbarPlayerMac.swift` | Câblage transport/volume/route, sélection de lecture, budget horizontal et popover de volume |
| `ToolbarPlaybackButtonMac.swift` | Hover, relief, pression, activation et appui maintenu |
| `PlayerVolumeSliderMac.swift` | Course native, dessin opaque, interpolation du clic et survol du bouton |
| `PlayerLCDMac.swift` | Verre, bordure, gradients et conteneur du contenu |
| `PlayerLCDContentMac.swift` | Présentation des métadonnées, activités, modes, pochette et commandes de piste |
| `LCDPlaybackPlotMac.swift` | Geste de scrub, waveform, niveaux et extinction du spectre |
| `PlayerReviewChecksMac.swift` | Régressions des subscriptions et de l’invalidation de l’idle |
| `TemporaryScratchSpace.swift` | Identité de session et nettoyage conservateur des dossiers abandonnés |
| `TemporaryMediaCache.swift` | Formats dérivés, lectures/écritures, tailles, plafond et éviction |
| `SpectrumAnalyzer.swift` | FFT et mémoire de travail appartenant à une seule analyse |

Les classes ont été séparées par responsabilité sans changer le module de l’application ni introduire de dépendance entre packages. La logique de file et les tests du cache restent dans MediaKit. Les valeurs par défaut de paramètres qui capturaient des singletons MainActor ont été remplacées par une injection explicite dans les contrôleurs natifs concernés.

## Réduction du travail effectué

- Le volume et la route AVKit ne sont réaffectés que lorsque leur valeur change.
- Le popover de file ne recrée les glyphes d’aléatoire/répétition qu’au changement de leur état.
- Le spinner ne s’arrête/redémarre plus à chaque rafraîchissement identique de l’activité.
- La projection de la file vers ses lignes utilise une tranche de l’ordre courant, sans fabriquer une copie intermédiaire des pistes restantes.
- Le cache calcule toujours sa taille pour respecter le plafond, mais ne trie les entrées que s’il doit réellement en évincer.
- La FFT utilise quatre buffers Float initialisés de 2 048 éléments, soit 32 Kio au total, alloués une fois par analyse et libérés par leur propriétaire. Le fallback FFT portable utilise la même mémoire de travail.
- Le décodage AVFoundation réutilise sa destination PCM. Seul le nombre d’échantillons du bloc courant est consommé ; la fin courte ne réutilise pas l’ancienne queue du buffer.

Le premier essai de réutilisation avec des tableaux Swift stockés comme propriétés ralentissait l’analyse complète. Il a été remplacé par la mémoire fixe après mesure. Les formats disque restent identiques : aucune invalidation du cache n’est nécessaire pour ce changement.

## Méthode de validation

`swift test` exécute 93 tests, dont cinq ignorés faute de FFmpeg dans ce lancement. Les nouveaux cas couvrent le déplacement groupé, la protection de la piste en cours, les sessions Scratch concurrentes, les sessions abandonnées, les anciens fichiers sans propriétaire et le fallback FFT sur une impulsion.

Les contrôles `IPPM_CHECK_INTERACTIONS`, `IPPM_CHECK_PLAYER` et `IPPM_CHECK_AUDIO` couvrent les vues natives, les régressions de la revue et le moteur réel. Les intégrations `qa-final` clair/sombre vérifient aussi les deux horloges après pause, le masquage avec fenêtre auxiliaire, la recherche, le Dock et le plein écran. Les variables et leurs conditions sont décrites dans [[Lecteur et session média]]. Une application QA doit avoir terminé sa sortie avant de remplacer ou signer son exécutable pour le lancement suivant.

La comparaison FFT isolée compile l’ancienne classe du commit `4d93b08` et la nouvelle en optimisation `-O`, dans le même processus. Une sonde stéréo de trois secondes donne les mêmes 1 928 octets encodés ; chaque paire de mesures de dix minutes compare aussi toutes les trames. Trois répétitions donnent une médiane de 351,18 ms avant et 264,95 ms après, soit 24,6 % de temps en moins pour ce calcul isolé. Cette mesure n’inclut ni AVFoundation ni le disque.

## Mesures de bout en bout

Builds release arm64 sur Apple M1 Max, macOS 15.7.1, même machine et même source WAV locale mono 16 bits à 44,1 kHz de dix minutes. Trois lancements par version, cache d’analyse dédié vide à chaque lancement ; les lectures chaudes suivent dans le même processus. Le WAV répète un bloc synthétique d’une seconde à 220/880 Hz. Le processus est lancé avec `IPPM_CHECK_ANALYSIS=<WAV>` et `IPPM_NO_LAUNCH_PANEL=1`. Le point de comparaison est le binaire release de `4d93b08` ; les mesures finales portent sur la FFT à mémoire fixe et le buffer PCM réutilisé.

| Chemin | Trois mesures avant | Trois mesures après | Médiane avant → après |
|---|---|---|---|
| Analyse complète WAV 10 min | 637 / 622 / 626 ms | 516 / 512 / 509 ms | 626 → 512 ms, −18.2 % |
| Premières trames | 112 / 105 / 104 ms | 107 / 105 / 100 ms | 105 → 105 ms |
| 100 écritures sous plafond, 2 000 entrées | 1,869155 / 1,828594 / 1,869988 s | 1,122141 / 1,147246 / 1,121612 s | 1.869 → 1.122 s, −40.0 % |

L’analyse produit toujours 1 024 bins de waveform, 12 000 trames stéréo et 388 112 octets dérivés. Les lectures chaudes restent sous la milliseconde (environ 0,2–0,3 ms sur ces relevés) ; leur différence est trop petite pour conclure à une accélération.

Le stress du cache utilise un dossier temporaire indépendant de 2 000 fichiers de 128 octets, un plafond de 200 Mio et 100 remplacements atomiques de la même entrée. La création des fichiers et la configuration sont hors de la fenêtre de mesure. Les exécutables avant/après, compilés en `-O`, sont alternés trois fois. Cette charge isole l’effet du tri évité sous plafond ; elle ne mesure ni l’import d’une bibliothèque ni la lecture utilisateur entière.

Les mesures n’ont pas été prises pendant une compilation ou une intégration UI. Ces gains courts sur un WAV synthétique ne sont pas extrapolés au décodage de MP3/AAC, aux autres ordinateurs ou à la consommation totale de l’application. Les vérifications de disposition 820–1 600 pt restent des contrôles de bornes et de hit-test, pas un benchmark comparatif de framerate.

## Limites conservées

Les anciens fichiers Scratch plats n’ont pas d’identité de propriétaire : ils sont laissés au nettoyage du système plutôt que supprimés pendant qu’un ancien build pourrait encore s’en servir. Un PID réutilisé ou un accès refusé est traité comme une session à conserver. Ces choix privilégient l’intégrité d’un travail actif sur la récupération immédiate de quelques fichiers temporaires.

Les mesures courtes de redimensionnement ne sont pas une mesure du framerate sur une grosse bibliothèque. Aucun gain CPU global ni consommation nulle du processus entier n’est déduit du seul arrêt des horloges du lecteur. Les gestes AirPods, les touches média physiques, les builds Windows/Linux et une migration complète de l’application en mode de langage Swift 6 ne sont pas validés par cette passe. Les avertissements historiques hors des composants du lecteur gardent leur propre périmètre.
