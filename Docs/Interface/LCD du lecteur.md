# LCD du lecteur de barre d’outils

Le conteneur macOS reste un verre natif translucide, creusé par des dégradés internes, affleurant le haut de la fenêtre et laissant 3 points sous le panneau. Le contenu conserve deux lignes, une petite pochette, les temps et une progression. Les commandes auxiliaires reprennent les valeurs du rail et des boutons natifs : attente de 400 ms au survol, fondu entrant de 180 ms et sortant de 160 ms, voile neutre à 6,5 % au survol et 13 % à la pression, glyphes gris secondaires et estompés quand la fenêtre perd le focus. Les trois boutons de transport utilisent désormais une ombre extérieure à la place du voile de survol : opacité 0,40 et rayon 1,7 pt au repos, puis 0,78 et 3,6 pt après le délai de 400 ms. L’appui réduit l’ombre à 0,015 et le rayon à 0,2 pt. Ils passent à 86 % pendant l’appui en 60 ms, puis retrouvent leur taille en 100 ms. Les changements d’ombre prennent 60 ms à l’appui et 120 ms au relâchement/survol. Play/Pause utilise directement les transitions SF Symbols d’AppKit, accélérées avec `.speed(3)` : Magic Replace sous macOS 15 et ultérieur, Replace sous macOS 14. Le système fournit les effets Draw lorsque disponibles sous macOS 26 ; aucun tracé simulé par masque n’est conservé. Réduire les animations donne directement le symbole final.

## État portable

`MediaKit/PlayerLCDModel.swift` définit les modes, le décodage des paroles LRC, les chapitres, le geste de scrub, la sélection des activités et les trames du spectre. Les préférences `playerLCDMode` et `playerShowsRemaining` sont enregistrées dans les réglages portables, avec des valeurs par défaut compatibles avec les anciens fichiers. La sélection de Paroles reste mémorisée même quand le contenu se replie sur Titre.

Au repos, le LCD n’affiche ni nom d’application ni nom du périphérique ; seule l’information d’espace libre reste disponible.

Le scrub garde une position proposée jusqu’au relâchement. Échap, un changement de piste ou une phase de défilement annulée abandonne cette proposition. Les chapitres s’aimantent à 6 points. Les gestes sans scrub possible sont ignorés dans la vue enfant : les renvoyer à AppKit recréerait une boucle avec le parent qui lui transmet le défilement. Le retour à la piste restaure sa vue d’origine, efface la recherche et transmet une demande de sélection/défilement à la table native ou à l’album déplié.

## Cadences et travail de fond

La waveform utilise les pics existants et les événements du moteur, sans nouvelle analyse ni cadence autonome. Les paroles et chapitres sont lus localement sur une tâche utility annulable ; aucun fournisseur de paroles réseau n’est appelé. Une seule échéance de paroles est armée, annulée en pause et quand la fenêtre est masquée.

Le rendu du spectre accepte des trames pré-calculées à 16 bandes par canal, interpole les valeurs et maintient les pics. Le générateur de PLR16 décode la piste avec la waveform dans une seule passe sur Mac, à 44,1 kHz stéréo. Une FFT de 2 048 échantillons fenêtrée Hann produit 16 bandes logarithmiques par canal à 20 Hz. Le cache de PLR17 conserve les trames sur disque ; un format non pris en charge garde la grille éteinte. Lorsqu’elles sont fournies, un CVDisplayLink plafonné à 30 Hz (10 Hz avec Réduire les animations) ne tourne que pendant la lecture, fenêtre visible et mode Spectre affiché. Aucun display link n’est créé pour une grille sans données. Les premières trames sont transmises dès que 200 ms d’audio sont décodées, puis par lots espacés d’au moins 500 ms pendant l’analyse. Un résultat ancien ou plus court ne remplace pas les données les plus récentes. Sur le WAV de contrôle de 2 min, les premières données sont disponibles en 135 ms contre 4,050 s pour le résultat complet dans le build de développement du 17 novembre 2026.

La progression est une vue transparente distincte, toujours au-dessus des métadonnées et indépendante de l’opacité du spectre. Son épaisseur passe de 2 à 4 pt en 180 ms au survol du LCD ; sa largeur de progression reste actualisée directement. Le bouton AirPlay conserve le sélecteur natif AVKit, avec des couleurs publiques par état et une opacité inactive de 30 %, réappliquées sur les événements d’activation de la fenêtre et de l’app.

En mode Spectre, le survol fond le titre et l’artiste au-dessus des barres en 180 ms, puis les retire en 160 ms au départ du pointeur, avec interruption fluide d’une transition en cours. À la pause, les niveaux retombent avec une enveloppe quadratique de 450 ms jusqu’à extinction complète. Les pics restent à leur hauteur pendant cette descente, attendent encore 120 ms, puis s’effacent en 160 ms ; le display link s’arrête à la fin. Les pics ne restent plus sur la rangée inférieure. Une reprise annule cette extinction. Fenêtre masquée ou Réduire les animations : extinction immédiate, sans horloge de transition.

Le mode de prévisualisation Spectrum utilise désormais le véritable fichier audio ; `spectrum-fixture` réserve les données synthétiques aux contrôles de dessin.

Les activités proviennent des imports, transferts/synchronisations (y compris leurs phases de conversion) et téléchargements de podcasts. Les mises à jour restent limitées aux événements existants, environ 500 ms. Une échéance d’une seconde évite d’afficher une progression fugitive ; la fin apparaît trois secondes avec une échéance unique. Les échecs restent jusqu’à acquittement. L’annulation d’une synchronisation demande confirmation ; les autres annulations sont directes. Les sources de fichiers et de livres audio cessent de lancer de nouveaux travaux dès l’annulation et une bibliothèque partiellement scannée n’est pas enregistrée.

## Contrôles reproductibles

- `swift test` couvre modes/replis, timing LRC, scrub borné/aimanté/annulé, sélection des activités, interpolation et pics du spectre, compatibilité des préférences.
- `IPPM_CHECK_PLAYER=1` contrôle le transport, le volume, les états d’activité et l’expiration de la notification de fin.
- `IPPM_PLAYER_PREVIEW=title|waveform|lyrics|spectrum|activity` avec `IPPM_PLAYER_FIXTURE=<WAV local>` et `IPPM_SNAPSHOT=<PNG>` permet de vérifier les différents rendus, son coupé et sans modifier la bibliothèque. Le spectre de cette prévisualisation analyse le WAV fourni ; `spectrum-fixture` injecte des trames synthétiques pour les contrôles de dessin.
- L’analyse reste indépendante du dessin : `IPPM_CHECK_ANALYSIS=<fichier>` mesure le décodage réel, vérifie waveform/spectre et leur réutilisation ; `IPPM_CHECK_AUDIO=<WAV>` vérifie aussi les publications de session sur un moteur réel.

Les lancements ordinaires gardent une fenêtre de niveau normal, visible dans Mission Control. `IPPM_FRONT` ne change plus son niveau ; un niveau flottant ne peut être demandé que lors d’une capture explicite `IPPM_SNAPSHOT`.

## Mesure de disposition

Le 16 novembre 2026, build macOS de développement arm64 : huit changements de largeur entre 820 et 1 600 points sur la fenêtre de contrôle, médiane 5,97 ms et maximum 6,79 ms pour le redimensionnement synchrone avec disposition du contenu. Ce chiffre inclut la fenêtre de test peu remplie, ne mesure pas le rafraîchissement à l’écran et ne remplace pas une mesure sur une bibliothèque volumineuse. Les assertions vérifient également la plage de largeur du LCD et sa marge inférieure.


## File À suivre et session média

Le popover À suivre utilise une NSTableView virtualisée. Seules les lignes visibles demandent leur pochette. La file garde la piste en cours, déduplique par identifiant, déplace les entrées déjà présentes et autorise insertions, réordonnancement, retrait, saut et effacement des seules pistes à venir. Le retour depuis le LCD garde la source de chaque insertion, même si plusieurs vues ont alimenté la file. Désactiver l’aléatoire restaure l’ordre d’origine avec les nouvelles insertions après la piste en cours.

Le protocole MediaSession et sa version simulée résident dans MediaKit. PlaybackController ne crée la session qu’à la première lecture. Il publie les événements de piste, durée disponible, lecture/pause, saut, vitesse, disponibilité et arrêt ; les ticks de progression ne publient rien. La position demandée est conservée pendant un seek asynchrone, puis confirmée par le moteur. La session macOS utilise MPNowPlayingInfoCenter et MPRemoteCommandCenter, sans intercepter les touches d’une autre application. Les pochettes sont décodées en arrière-plan. La position publiée lors de leur arrivée est extrapolée pour éviter un retour en arrière.

Les contenus parlés disposent des sauts de 15/30 secondes et des vitesses 0,75× à 2×, mémorisées par type pendant la session. La musique revient à 1×. Le menu du Dock est construit à la demande ; le menu ••• ouvre la bibliothèque, l’éditeur de métadonnées, les favoris disponibles et les vitesses des contenus parlés.

## Cache temporaire

TemporaryMediaCache centralise Spectrum, Waveforms et Scratch sous le dossier temporaire de l’ordinateur, jamais sur l’iPod. Les clés SHA-1 portent sur le chemin, la taille et la date du fichier source ; les noms des fichiers ne divulguent aucun titre ni chemin. Le format v1 du spectre commence par IPSP0001 et contient 32 octets par image, à 20 Hz. La waveform IPWF0001 contient au plus 1 024 Float32 little-endian. Les trames du spectre sont écrites progressivement, puis renommées atomiquement ; une annulation jette le fichier incomplet. Les fichiers de plus de deux heures gardent seulement leur waveform et un marqueur évitant de retenter le spectre.

Un cache mémoire borné reste devant le disque. Ses succès mettent également à jour la date d’utilisation des fichiers pour l’éviction LRU. Le plafond global est de 200 Mio par défaut. Le lancement nettoie Scratch plus ancien que la session, retire les versions obsolètes et applique le plafond. Les réglages Advanced sont portables : conservation/effacement par catégorie, plafond, vidage immédiat et ouverture du dossier. Les tailles sont calculées hors du fil principal, à l’ouverture et après modification/vidage. La fermeture attend l’annulation de l’analyse avant le ménage demandé. Les erreurs de disque restent silencieuses et la piste en cours conserve son résultat en mémoire.

## Mesures du spectre — 16 novembre 2026

Le FFT optimisé a été mesuré séparément du décodage sur PCM synthétique :

| Durée | FFT seul, build optimisé | Trames | Fichier Spectrum |
|---|---:|---:|---:|
| 3 min | 0,089 s | 3 600 | 115 208 octets |
| 10 min | 0,296 s | 12 000 | 384 008 octets |
| 2 h | 3,772 s | 144 000 | 4 608 008 octets |

Le chemin complet AVFoundation + waveform + FFT + écriture a aussi été mesuré dans le build de développement non optimisé :

| Source | Durée réelle | Analyse complète | Waveform + Spectrum |
|---|---:|---:|---:|
| MP3 de la bibliothèque | 179,984 s | 5,112 s | 119 280 octets |
| MP3 de la bibliothèque | 600,268 s | 16,880 s | 388 272 octets |
| WAV mono synthétique | 2 h | 197,616 s | 4 612 080 octets |

Ces chiffres de décodage ne représentent pas le build de production optimisé. Les lectures chaudes mesurées avant le dernier ajustement de date LRU prenaient 0,2–0,3 ms. L’ouverture/disposition/effacement d’une file native de 5 000 lignes prenait environ 11–13 ms dans les contrôles ; ce chiffre inclut le harnais de test et ne mesure pas une interaction humaine.

Les 88 tests Swift (5 ignorés), les contrôles ciblés lecteur/audio réel et le contrôle global d’interface passent. La sidebar termine son glissement via le callback du backend, y compris après un repli natif. Les touches média physiques et AirPods ne sont pas validés par les commandes simulées ni par les assertions d’API.

## Charge CPU du lecteur

Mesure du processus complet macOS arm64 en build de développement, WAV silencieux de 2 min en cache, bibliothèque de prévisualisation vide : 15 s de stabilisation, puis différence du temps CPU `ps` sur 5 s. 100 % représente un cœur. Le compteur est arrondi au centième de seconde ; ces fenêtres courtes donnent un ordre de grandeur, pas une garantie.

| Mode | CPU du processus |
|---|---:|
| Titre, lecture | 3,78 % |
| Waveform, lecture | 4,58 % |
| Paroles, lecture | 3,79 % |
| Spectre, lecture | 11,17 % |
| Spectre, pause | 0,00 % |
| Spectre, fenêtre masquée, audio en lecture | 0,60 % |

La lecture masquée conserve le coût du moteur audio ; le display link et les événements périodiques de progression sont arrêtés. Un relevé séparé de la pause sur 25 s ne consomme que 0,01 s CPU. L’échantillonnage des piles pendant la pause montre le fil principal en attente, sans boucle de rendu active. Les premiers relevés à 8 s de stabilisation ont donné des pointes non reproduites après stabilisation ; ils ne servent pas à conclure sur la consommation au repos. Les mesures optimisées ci-dessous complètent ce relevé de développement.


## Validation native finale — 18 novembre 2026

`IPPM_PLAYER_PREVIEW=qa-final IPPM_PLAYER_QA=1 IPPM_PLAYER_FIXTURE=<WAV>` exécute une intégration avec le vrai moteur et la vraie session macOS. Les deux processus lancés avec `-AppleInterfaceStyle Light` et `Dark` passent : métadonnées Now Playing, actions lecture/pause du menu fourni au Dock, vidage du cache disque pendant la lecture sans perdre les données affichées, progression audio, entrée/sortie du plein écran, fermeture/masquage et réouverture sans interrompre la session. `IPPM_QA_APPEARANCE=light|dark` fixe uniquement l’apparence de ce processus. Les contrôles du lecteur passent également avec Réduire les animations activé ; le réglage système d’origine est restauré après vérification.

Depuis le correctif suivant du 18 novembre, la barre de 44 pt est un `PlayerHeaderMac` intégré au contenu : transport, volume, LCD, file et recherche restent dans la fenêtre principale, sans `NSToolbar`. Le header suit le remplacement initial de `contentView` par SwiftCrossUI via KVO, puis les redimensionnements natifs, sans attente périodique. La recherche conserve un `NSSearchField` natif de 170 × 28 pt et un bouton compact sous 900 pt.

Le mode plein écran retire temporairement le style `titled` avant l’entrée, puis le restaure avant la sortie, y compris en cas d’échec de transition. La fenêtre déclare explicitement `fullScreenPrimary` : elle reste éligible au plein écran et à sa sortie même sans titre. Le patch AppKit expose `acceptsKeyWithoutTitle`, activé seulement sur cette fenêtre : elle conserve les statuts key/main et le menu système continue de lui envoyer la commande de sortie. AppKit peut malgré cela conserver une fenêtre native de titre qui réapparaît au survol de la barre de menus. Le chrome rend son contenu masqué, son fond transparent et ses événements souris traversants pendant le plein écran. L’hôte est retrouvé depuis la vue native, ou, si AppKit l’a recréée, par sa classe de fenêtre de titre dans ce processus, sur le même écran et à la même largeur. Ce fallback dépend de la structure AppKit observée ; le contrôle natif couvre son rendu.

Deux observations KVO réappliquent le masquage et les événements traversants si AppKit les réinitialise lors du survol. Elles sont retirées avant de restaurer l’état initial à la sortie du plein écran. Aucune cadence de surveillance n’est ajoutée. Les boutons système restent natifs en mode fenêtre et sont restaurés à la sortie, puis confirmés au tour de boucle suivant pour couvrir la restauration tardive du style par AppKit. Les contrôles de lecture ne changent jamais de parent ni de fenêtre. Les contrôles attendent les notifications réelles de fin de transition, et vérifient aussi les clics après retour au mode fenêtre.

La disparition surveillée du processus a produit un statut de sortie SIGTERM (15), sans crash correspondant. Cela identifie un arrêt externe, sans prouver quel processus l’a envoyé. Le bundle local de revue utilise maintenant un identifiant et un exécutable propres (`iPodPlayerReview`), afin que l’arrêt global d’un autre build portant le nom habituel ne l’atteigne pas.

Limites : aucun matériel Bluetooth/AirPods disponible. Les actions du menu Dock ont été exécutées via le menu réel du délégué et Now Playing vérifié via les API publiques ; l’ouverture visuelle des panneaux système et les touches média physiques ne sont pas validées.

## Analyse complète optimisée — 18 novembre 2026

Build release macOS arm64, WAV de contrôle synthétiques, AVFoundation + waveform + FFT + écriture. Ces sources ne sont pas les MP3 du tableau de développement ; les chiffres ne mesurent pas une accélération sur ces MP3.

| Durée WAV | Premières trames | Analyse complète | Waveform + Spectrum | Lecture chaude |
|---|---:|---:|---:|---:|
| 3 min | 0,127 s | 0,419 s | 119 280 octets | 0,3 ms |
| 10 min | 0,106 s | 0,583 s | 388 080 octets | 0,2 ms |
| 2 h | 0,107 s | 5,925 s | 4 612 080 octets | 0,3 ms |


Le relevé release du processus complet (15 s de stabilisation, fenêtre de 5 s) donne 4,00 % en Titre, 6,79 % en Waveform et 4,59 % en Spectre, sur le même WAV silencieux de contrôle. Fenêtre masquée en lecture : 0,40 %. Ces mesures courtes varient avec l’occlusion et les interactions ; elles ne constituent pas une comparaison contrôlée avec le tableau de développement. Le premier relevé Paroles a été écarté, car sa fenêtre était occultée.

Les relevés release « pause » sont écartés : un échantillonnage des piles a capturé du suivi de clic dans `ToolbarPlaybackButton.mouseDown`, donc le processus n’était pas au repos. Ils ne prouvent ni un coût nul ni une régression. Le contrôle précédent au repos en build de développement et l’arrêt événementiel du display link restent les éléments disponibles pour ce cas.

Un second relevé Paroles, avec fenêtre visible, 25 s de stabilisation et une fenêtre de mesure de 10 s après échantillonnage des piles, donne 0,40 %. Il utilise une méthode plus longue et reste distinct de la première série.


## Barre intégrée et disposition

Le contrôle natif de disposition vérifie huit largeurs entre 820 et 1 600 pt, l’alignement vertical des commandes sur les boutons système, l’égalité des marges de chaque côté du volume/LCD, ainsi que le hit-test réel des contrôles sous la zone de titre. Après sortie du plein écran, ces assertions sont exécutées à nouveau. Les tests de recherche vérifient sa réduction, l’ouverture avec focus, la transmission de la saisie à la page et la disparition quand la page abandonne sa recherche. En mode fenêtre, le glisser sur une zone vide déplace la fenêtre et le double clic suit le choix macOS d’agrandissement ou réduction. En plein écran, ces gestes sur le fond du header sont ignorés afin de ne pas redimensionner une fenêtre encore dans son espace plein écran. Le verre de fond est lui aussi attaché au contenu, car le changement de style remplace le cadre natif.

Validation manuelle supplémentaire : entrée par le bouton vert, ouverture du menu View en plein écran, commande native Exit Full Screen et retour des boutons fermer/agrandir/réduire. Le contrôle d’intégration vérifie aussi le statut key/main et envoie la sortie via la chaîne de réponse native, plutôt que directement à la fenêtre.


## Offsets des boutons et révélation native — 18 novembre 2026

La référence visuelle du propriétaire donne des centres à x = 20, 40 et 60 pt, et y = 22 pt sous le bord supérieur. Le placement contraint les deux axes des boutons natifs ; il est vérifié de 820 à 1 600 pt et après la sortie du plein écran. Les espacements du lecteur sont ensuite recalculés depuis ces positions.

Le contrôle de la bande native ne se limite plus à son alpha au repos : il force l’hôte de titre à alpha 1, tente de rétablir son contenu et ses événements souris comme le ferait AppKit, puis vérifie qu’il reste masqué et traversant. Un rendu bitmap de son cadre n’a aucun pixel opaque (échantillonnage tous les 4 pixels). Ce contrôle passe en clair et en sombre avec entrée par le bouton vert et sortie par la chaîne de réponse du menu système.


## Transitions du retrait et des boutons système — 18 novembre 2026

Les véritables boutons AppKit sont hébergés dans le header du contenu en mode fenêtre. Ils gardent leurs actions système et leurs centres à 20/40/60 pt, à 22 pt du haut, dès le début de la sortie du plein écran. Quand AppKit recrée ses boutons, le chrome adopte ces nouvelles instances et remplace ses observations de cadre. Leurs parents gardent ainsi une hauteur de 44 pt pendant la transition, sans imposer une géométrie aux conteneurs de titre qu’AppKit anime lui-même. La surface auxiliaire native reste masquée pendant la sortie, puis retrouve son état initial une fois retirée de l’écran.

Après l’entrée en plein écran, le transport passe d’un retrait de 78 pt plus son espace adaptatif à un retrait de 12 pt, sans espace adaptatif. Une translation Core Animation de 250 ms avec accélération/décélération anime ce changement ; la sortie déclenche le mouvement inverse. Une interruption repart de la position de présentation. Réduire les animations applique directement la position finale. Cette transition ne crée aucune horloge au repos.

Les contrôles natifs vérifient l’aller-retour du retrait, la durée de l’animation, l’absence de clipping pendant les passes de disposition de sortie, ainsi que les actions réelles des boutons vert, réduire et fermer. Les intégrations clair/sombre contrôlent aussi la conservation de la lecture, la réouverture depuis le Dock et le maintien de la bande native invisible au survol.


## Curseur de volume — 19 novembre 2026

La cellule de volume utilise un bouton de 7 pt pour le dessin comme pour la course native. Le centre du bouton va exactement d’un bout à l’autre de la barre visible ; le rectangle de barre interne d’AppKit reste natif afin que son calcul de glissement conserve la même échelle. Le placement du volume après Next utilise le rectangle visible, y compris dans le popover compact. Barre et bouton partagent le même axe vertical.

Le bouton est dessiné avec une couleur grise solide, adaptée au thème et à l’activation de la fenêtre, ou la couleur d’accent solide ; son alpha reste à 1 pendant les fondus. La barre ne transparaît plus à travers. Le survol local du bouton (avec 3 pt de tolérance) déclenche immédiatement une échelle de 1 à 12/7 en 100 ms, puis le retour en 90 ms. La couleur garde le délai du rail ; l’appui passe à 1,45. Les interruptions repartent de la présentation courante, les mises à jour de géométrie ne modifient pas la taille de base, et Réduire les animations applique directement l’état cible. Le bouton agrandi n’est pas coupé aux extrémités.

Le contrôle monté dans la vraie toolbar vérifie les valeurs 0/25/50/75/100 %, la coïncidence du centre avec les extrémités visibles, le déplacement via les méthodes de suivi natives de NSSliderCell, l’opacité de la couleur, l’échelle immédiate et l’annulation du survol. Les intégrations clair/sombre et les contrôles globaux/lecteur/audio passent après ce changement.


## Composition et relief — 20 novembre 2026

La pochette remplit un carré de 41 pt sur toute la hauteur, au bord gauche du LCD, avec recadrage proportionnel. Elle demande une miniature de 128 pixels hors du fil principal ; en son absence, le symbole musical garde sa taille native. La timeline part du coin inférieur droit de la pochette jusqu’au bord droit du LCD, sans marge latérale ni coins arrondis propres. Les chevrons de changement de mode se révèlent sur le bord gauche de la pochette. Les métadonnées sont centrées dans la place restante ; AirPlay se trouve à l’extérieur du LCD.

Le bouton d’actions accentué est accolé au titre, même sans survol en mode Titre. En mode Spectre, il partage le fondu du titre et reste disponible tant que celui-ci est affiché. Le spectre laisse 28 pt à chaque extrémité de sa zone, pour dégager le mode et AirPlay. `PlayerSpectrumPeakRelease` sépare le délai/fondu des pics de l’extinction des niveaux ; reprise et Réduire les animations interrompent immédiatement cette fin d’affichage.

Le volume s’inspire de la référence iTunes fournie : piste sombre de 4 pt, remplissage clair, bouton opaque de 7 pt au repos et 12 pt au survol, avec bord fin et ombre légère. Sa course reste native, sa couleur de survol accentuée est adoucie et l’agrandissement réactif précédent est conservé.

Validation : contrôle natif du relief sans voile, ombre aplatie à l’appui et symbole final après interruption ; contrôles de la pochette/timeline bord à bord et du bouton d’actions avec le titre et son survol dans le spectre ; test partagé du délai des pics, de leur extinction et de la reprise. Les intégrations macOS couvrent également recherche, plein écran, cache pendant lecture et boutons système.


## Ergonomie du bandeau — 20 novembre 2026

Les centres des boutons système sont maintenant à 20/38/56 pt, à 22 pt du haut. Le transport commence à 74 pt avec un espace adaptatif de 0 à 8 pt. Le volume suit Next : son haut-parleur commence après le même espace visible que celui entre le bouton vert et Back (15 à 23 pt selon la largeur). AirPlay utilise une plaque de 39 × 26 pt, à 8 pt à gauche du LCD, en miroir de la file À suivre.

En plein écran, Back se place à 56 pt, soit le bord droit du rail de 44 pt plus 12 pt pour dégager son coin. La révélation native par la barre des menus affiche les véritables boutons système dans le header du contenu et repousse le transport à 82 pt. Le passage du pointeur dans le header conserve les boutons cliquables jusqu’à sa sortie. La bande de titre auxiliaire reste transparente et traversante. Les déplacements du transport utilisent la transition interrompable de 250 ms ; le contrôle d’intégration sort du plein écran en cliquant le bouton vert révélé.

Le clic sur la piste de volume anime simultanément le bouton et le remplissage en 140 ms avec décélération. Le glissement natif conserve une réponse directe et interrompt cette interpolation. Le haut-parleur garde un canevas de 20 × 16 pt et une trompette fixe ; seules les ondes changent avec le niveau. Les images sont mises en cache. Le transport désactive également le highlight natif de sa cellule à l’appui pour conserver son gris et son relief aplati.

Les chevrons haut/bas du LCD se révèlent par fondu et translation de 8 pt en 130 ms, puis disparaissent en 100 ms. Ils restent absents au repos et parcourent les vues disponibles ; les paroles vides sont ignorées. Leur clic droit conserve le menu des modes.

La recherche conserve le bezel natif et son ombre. Son focus ajoute un contour d’accent serré, sans halo externe, et une échelle de 1,025 en 120 ms. Le véritable éditeur AppKit défile horizontalement jusqu’au curseur pour une longue saisie ; ses réglages sont restaurés au départ du focus. Échap conserve la requête et retire le focus ; un clic extérieur le retire sans absorber le clic. La perte d’activation retire également le focus. Les animations sont finies et ne créent aucun travail au repos.

Validation macOS : volumes 0/25/50/75/100 %, clic animé et survol réversible, géométrie entre 820 et 1 600 pt, recherche longue de 540 caractères, Échap/clic extérieur, contrôles système révélés en plein écran et continuité de lecture. La disposition synchrone du build de développement mesurée sur cette fenêtre de contrôle donne une médiane de 2,51 ms et un maximum de 2,96 ms ; ce relevé court ne mesure pas une bibliothèque volumineuse.


## Largeur adaptative du volume — 20 novembre 2026

Le slider atteint 132 pt, contre 72 pt auparavant. Sa largeur partage le budget horizontal avec le LCD : elle descend progressivement jusqu’à 52 pt selon la place réellement disponible, après réservation d’AirPlay, de la file et du champ de recherche ou de sa loupe. Le passage compact ne dépend plus du seuil fixe de 1 000 pt ; il intervient uniquement lorsque le slider minimal et le LCD de 280 pt ne tiennent plus ensemble. Les espacements des commandes et la taille du bouton de volume sont conservés. Le redimensionnement réutilise la vue native et ne réinstalle pas le slider à chaque passe de disposition.

Contrôle natif sombre : slider de 132 pt à 1 240/1 600 pt, 94,6 pt à 1 000 pt et 77 pt à 820 pt avec recherche réduite. Les assertions vérifient la plage 52–132 pt et l’absence de chevauchement avec AirPlay et les contrôles à droite, y compris après le plein écran.
