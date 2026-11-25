# LCD du lecteur de barre d’outils


État visuel au 22 novembre 2026 ; mécanismes de robustesse et mesures actualisés dans [[Corrections de revue du lecteur]]. Architecture et correspondance PLR1–19 : [[Lecteur et session média]]. Constats et limites de validation : [[Revue du lecteur novembre 2026]]. Les sections datées plus bas conservent les étapes et mesures historiques ; le tableau suivant décrit les dimensions actuelles.

## Disposition actuelle

| Élément | Géométrie et interaction |
|---|---|
| Header | 44 pt, dans le contenu de la fenêtre ; aucune `NSToolbar` |
| Boutons système | Centres x = 20/38/56 pt ; y = 22 pt sous le haut ; boutons standard créés par AppKit dans le header, indépendants des instances du titlebar ; masque d’autoresize retiré |
| Transport | Groupe x = 74 pt avec espace adaptatif 0–8 pt ; SF Symbols 13 pt et Play/Pause 20 pt ; entraxe 27 pt ; Play/Pause/Stop partagent un centre d’encre mesuré |
| Plein écran | Groupe x = 52 pt au repos, soit rail 44 pt + 8 pt ; x = 82 pt lorsque les boutons système sont révélés ; translation 250 ms commune au transport et au volume |
| Volume | Slider 117 pt au maximum (un tiers de plus que 88 pt), réduction progressive jusqu’à 44 pt puis popover compact si nécessaire ; espace après Next égal à l’espace visible feux/Back + 3 pt |
| Bouton de volume | 7 pt au repos, 9 pt au survol ; couleur opaque ; échelle 100 ms à l’entrée et 90 ms à la sortie ; teinte accentuée après 400 ms ; anneau de masque 1 px à 1,5 pt ; remplissage activé atténué à 35 % quand la fenêtre est inactive |
| Réglage du volume | Clic de piste : bouton et remplissage animés 140 ms ; glissement natif direct ; trompette de l’icône fixe ; symbole 10 pt et slider rapproché de 7 pt |
| LCD | Hauteur 41 pt, largeur 280–460 pt selon le budget ; ancré au haut, marge inférieure 3 pt ; pochette 41 × 41 pt |
| Timeline | Capsule opaque de 5 × 9 pt, haut arrondi et bas plat, anneau de masque 1 px à 1,5 pt ; fondu entrant 180 ms et sortant 160 ms au survol, teinte accentuée après 400 ms (180 ms) sans changement de taille ; ancrée sur la position de lecture, jamais sur le pointeur ; piste 2 → 4 pt au survol ; infobulle de temps sur le pointeur |
| AirPlay et file | Plaques 39 × 26 pt, espacées de 8 pt de part et d’autre du LCD ; AirPlay à gauche, file à droite |
| Modes | Chevrons de 16 pt au bord droit du LCD, sous la timeline dans l’ordre de composition, révélés 130 ms et retirés 160 ms ; cachés en idle |
| Recherche | Champ natif 170 × 24 pt, ou loupe quand la fenêtre se réduit ; focus natif (amorçage unique `FocusRingPrimerView`), bordure au repos / fond plein au focus et en arrière-plan, texte affleurant le `×` et recadré sans ellipse dès le début au repos |
| Défocus recherche | Échap conserve le texte et retire le focus ; clic extérieur défocus et réinitialise l’affichage au début ; perte d’activation garde le focus si retour par toolbar/Dock/`⌘Tab` |

Le verre reste actif visuellement quand la fenêtre est en arrière-plan ; les contrôles prennent leur teinte inactive. Le transport remplace le voile par un relief extérieur, renforcé après le délai de survol, presque éteint et réduit à 86 % à l’appui. Le highlight blanc de la cellule native est désactivé. Play/Pause et Stop utilisent un fondu ancré sur le centre d’encre du glyphe (0,75 pt de correction horizontale entre Play et Pause) en réponse au clic ou à la barre d’espace ; le glyphe ne se translate pas pendant l’animation. Les changements de piste et commandes distantes mettent le symbole à jour sans effet. Option maintenue pendant le survol du header affiche `stop.fill` ; son clic arrête et décharge la lecture. Les infobulles du transport sont retirées, les libellés d’accessibilité conservés.

Le conteneur macOS reste un verre natif translucide, creusé par des dégradés internes, affleurant le haut de la fenêtre et laissant 3 points sous le panneau. La pochette remplit la hauteur de 41 pt au bord gauche ; la timeline part de son coin inférieur droit jusqu’au bord droit du LCD. Les métadonnées gardent deux lignes. Les commandes auxiliaires reprennent les valeurs du rail et des boutons natifs : attente de 400 ms au survol, fondu entrant de 180 ms et sortant de 160 ms, voile neutre à 6,5 % au survol et 13 % à la pression, glyphes gris secondaires et estompés quand la fenêtre perd le focus. Les trois boutons de transport utilisent désormais une ombre extérieure à la place du voile de survol : opacité 0,40 et rayon 1,7 pt au repos, puis 0,78 et 3,6 pt après le délai de 400 ms. L’appui réduit l’ombre à 0,015 et le rayon à 0,2 pt. Ils passent à 86 % pendant l’appui en 60 ms, puis retrouvent leur taille en 100 ms. Les changements d’ombre prennent 60 ms à l’appui et 120 ms au relâchement/survol. Play/Pause et Stop utilisent ce fondu ancré plutôt que les transitions SF Symbols d’AppKit ; Réduire les animations donne directement le symbole final.

## État portable

`MediaKit/PlayerLCDModel.swift` définit les modes, le décodage des paroles LRC, les chapitres, le geste de scrub, la sélection des activités et les trames du spectre. Les préférences `playerLCDMode` et `playerShowsRemaining` sont enregistrées dans les réglages portables, avec des valeurs par défaut compatibles avec les anciens fichiers. La sélection de Paroles reste mémorisée même quand le contenu se replie sur Titre.

Au repos, le LCD n’affiche ni nom d’application ni nom du périphérique ; seule l’information d’espace libre reste disponible.

Le scrub garde une position proposée jusqu’au relâchement. Échap, un changement de piste ou une phase de défilement annulée abandonne cette proposition. Le correctif de revue verrouille désormais l’ensemble du geste après Échap : continuer à glisser ne déclenche plus de seek avant un nouvel appui. Les chapitres s’aimantent à 6 points. Les gestes sans scrub possible sont ignorés dans la vue enfant : les renvoyer à AppKit recréerait une boucle avec le parent qui lui transmet le défilement. Le retour à la piste restaure sa vue d’origine, efface la recherche et transmet une demande de sélection/défilement à la table native ou à l’album déplié.

## Cadences et travail de fond

La waveform utilise les pics existants et les événements du moteur, sans nouvelle analyse ni cadence autonome. Les paroles et chapitres sont lus localement sur une tâche utility annulable ; aucun fournisseur de paroles réseau n’est appelé. Une seule échéance de paroles est armée, annulée en pause et quand la fenêtre est masquée.

Le rendu du spectre accepte des trames pré-calculées à 16 bandes par canal, interpole les valeurs et maintient les pics. Le générateur de PLR16 décode la piste avec la waveform dans une seule passe sur Mac, à 44,1 kHz stéréo. Une FFT de 2 048 échantillons fenêtrée Hann produit 16 bandes logarithmiques par canal à 20 Hz. Le cache de PLR17 conserve les trames sur disque ; un format non pris en charge garde la grille éteinte. Lorsqu’elles sont fournies, un CVDisplayLink plafonné à 30 Hz (10 Hz avec Réduire les animations) ne tourne que pendant la lecture, fenêtre visible et mode Spectre affiché. Aucun display link n’est créé pour une grille sans données. Les premières trames sont transmises dès que 200 ms d’audio sont décodées, puis par lots espacés d’au moins 500 ms pendant l’analyse. Un résultat ancien ou plus court ne remplace pas les données les plus récentes. Sur le WAV de contrôle de 2 min, les premières données sont disponibles en 135 ms contre 4,050 s pour le résultat complet dans le build de développement du 17 novembre 2026.

La progression est une vue transparente distincte, toujours au-dessus des métadonnées et indépendante de l’opacité du spectre. Son épaisseur passe de 2 à 4 pt en 180 ms au survol de sa propre bande inférieure de 7 pt ; sa largeur de progression reste actualisée directement. Le bouton AirPlay conserve le sélecteur natif AVKit, piloté par une plaque `ToolbarPlaybackButton` de 39 × 26 pt identique à celle de la file. Les deux utilisent des SF Symbols de 14 pt et partagent teinte inactive, survol et appui. AVKit garde la présentation des routes ; le bouton visible relaie son action native et suit ses événements d’ouverture/fermeture.

En mode Spectre, le survol conserve les barres sans superposer les métadonnées ni afficher un temps flottant. L’écart entre canaux est de 24 pt. À la pause, les niveaux descendent à vitesse constante jusqu’à zéro, en 840 ms au maximum ; les colonnes basses s’éteignent plus tôt. Chaque crête attend l’extinction du dernier segment de sa propre colonne, garde sa hauteur 200 ms, puis disparaît en 220 ms. Un seul display link pilote ce relâchement borné ; il s’arrête lorsque tous les niveaux et crêtes sont éteints. Reprise, masquage et Réduire les animations interrompent proprement l’enveloppe.

La pochette sans image dessine un fond translucide avec la note musicale. Le titre et l’artiste descendent de 2 pt. Le titre reste centré dans la zone utile, indépendamment du bouton •••, qui se révèle en fondu à sa droite au survol. Les temps partagent des marges de 6 pt et 22 pt, cette dernière réservant la place des chevrons et un intervalle avec le temps restant. Les chevrons restent au bord droit et gardent leur rendu actif pendant le fondu sortant de 160 ms. Le sous-titre défilant réserve 60 pt de chaque côté pour les horloges (90 pt à gauche avec une vitesse parlée), afin que les textes ne se chevauchent jamais.

Le volume utilise `speaker.slash.fill` à zéro et les vrais `speaker.wave.1.fill` à `speaker.wave.3.fill`. Une surface d’icône fixe, alignée à gauche, conserve la position du haut-parleur ; un fondu de 140 ms introduit ou retire les ondes. Les changements externes et mute animent aussi le remplissage et le curseur, sans ralentir le glissement natif.

### Nouvelle forme d’onde

`LCDWaveformMac.swift` isole le rendu de l’analyse : une enveloppe symétrique lissée et mise en cache (256 points au maximum), un passage coloré par dégradé et un curseur fin. Les événements existants de position déclenchent des interpolations Core Animation finies de 250 ms, interrompues en pause, seek, masquage ou Réduire les animations. Aucun nouveau timer, décodage ou paquet n’est ajouté.

Références étudiées : [DSWaveformImage](https://github.com/dmrschmidt/DSWaveformImage), pour la séparation données/rendu et la progression colorée, et [AudioKit/Waveform](https://github.com/AudioKit/Waveform), pour le rendu animé. Le choix ici reste un rendu AppKit/Core Animation local utilisant les échantillons déjà disponibles.


Le mode de prévisualisation Spectrum utilise désormais le véritable fichier audio ; `spectrum-fixture` réserve les données synthétiques aux contrôles de dessin.

Les activités proviennent des imports, transferts/synchronisations (y compris leurs phases de conversion) et téléchargements de podcasts. Les mises à jour restent limitées aux événements existants, environ 500 ms. Une échéance d’une seconde évite d’afficher une progression fugitive ; la fin apparaît trois secondes avec une échéance unique. Les échecs restent jusqu’à acquittement. L’annulation d’une synchronisation demande confirmation ; les autres annulations sont directes. Les sources de fichiers et de livres audio cessent de lancer de nouveaux travaux dès l’annulation et une bibliothèque partiellement scannée n’est pas enregistrée.

## Contrôles reproductibles

- `swift test` couvre modes/replis, timing LRC, scrub borné/aimanté/annulé, sélection des activités, interpolation et pics du spectre, compatibilité des préférences.
- `IPPM_CHECK_PLAYER=1` contrôle le transport, le volume, les états d’activité et l’expiration de la notification de fin.
- `IPPM_PLAYER_PREVIEW=title|waveform|lyrics|spectrum|activity` avec `IPPM_PLAYER_FIXTURE=<WAV local>` et `IPPM_SNAPSHOT=<PNG>` permet de vérifier les différents rendus, son coupé et sans modifier la bibliothèque. Le spectre de cette prévisualisation analyse le WAV fourni ; `spectrum-fixture` injecte des trames synthétiques pour les contrôles de dessin.
- L’analyse reste indépendante du dessin : `IPPM_CHECK_ANALYSIS=<fichier>` mesure le décodage réel, vérifie waveform/spectre et leur réutilisation ; `IPPM_CHECK_AUDIO=<WAV>` vérifie aussi les publications de session sur un moteur réel.

Les lancements ordinaires gardent une fenêtre de niveau normal, visible dans Mission Control. `IPPM_FRONT` ne change plus son niveau ; un niveau flottant ne peut être demandé que lors d’une capture explicite `IPPM_SNAPSHOT`.

## Transitions de piste et interactions — complément du 22 novembre

Le conteneur LCD ne reçoit plus de transition globale. Seuls les textes de piste fondent ; le placeholder et le verre restent stables. La note de remplacement est une image native persistante indépendante de la cellule du bouton. Deux pistes sans pochette conservent le même rendu. Les temps gardent une opacité de vue de 1 ; le texte précédent reste jusqu’à disponibilité de la nouvelle durée, puis un fondu de contenu de 180 ms le remplace sans passer par `--:--` entre les pistes.

Le contrôleur ignore les états moteur synchrones pendant le remplacement. Sur Mac, l’observation du taux AVPlayer vérifie l’identité de l’item et ignore les taux nuls de démarrage jusqu’à une progression audio effective. Un taux positif seul ne suffit pas à conclure que le chargement est terminé. Les pauses explicites continuent de mettre l’interface à jour immédiatement. Le contrôle réel remplace une piste pendant la lecture et vérifie qu’aucun état `playing = false` n’est publié.

L’infobulle de la mini timeline suit le point local du curseur avec un décalage de 4 pt et se borne aux bords horizontaux. Le volume utilise une sensibilité de 0,0015 par unité de défilement précis et 0,004 par unité de molette. Le scroll retire le survol du curseur et le bloque jusqu’au prochain mouvement de souris ; aucun délai ou polling n’est ajouté.

Titre et sous-titre trop longs utilisent deux copies de texte pour un défilement continu vers la gauche à 20 pt/s, avec une pause de 2,4 s au début de chaque boucle. Les animations sont retirées en pause ou quand la fenêtre est masquée ; les textes qui tiennent dans leur zone et Réduire les animations restent immobiles. Aucun timer ne pilote le défilement.

### Validation du complément

Builds de développement et optimisé ; 131 tests, 7 ignorés, aucun échec. L’intégration native en clair/sombre remplace réellement la piste AVPlayer et vérifie l’absence d’état pause intermédiaire, puis contrôle la composition avec des titres longs, les deux copies de défilement, leur suppression en pause et leur reprise. Les contrôles de volume vérifient la sensibilité réduite et l’absence de grossissement après scroll jusqu’au mouvement du pointeur. Plein écran, pause/reprise et arrêt des horloges restent validés.

Un lancement du contrôle direct de disposition a rencontré le `PackageDropOverlayView` du module de plug-ins lors d’un `hitTest` hors événement pointeur (`WindowChromeMac.swift:141`). Ce contrôle dépend de `NSApp.currentEvent` ; le scénario d’intégration avec la fenêtre active valide les mêmes contrôles de géométrie. Le chemin de dépôt de plug-ins n’est pas changé par ce lot. La limitation du contrôle global des menus de colonnes signalée plus bas reste distincte.

### Stabilisation des boutons système et glissement du volume

Le centrage suit les notifications de frame et de bounds des trois boutons natifs, ainsi que la fin de la disposition du header. Une modification réentrante programme une unique passe de réconciliation sur le prochain tour du main thread ; les coordonnées identiques ne sont pas réappliquées. Les tailles utilisées pour le centrage sont celles des frames réelles. Un jeu natif partiel pendant une transition ne remplace pas les trois boutons déjà hébergés. Aucun timer ou polling n’est ajouté.

Le volume et le transport prennent chacun leur position de présentation courante, puis rejoignent ensemble leur nouvelle position en 250 ms à l’entrée/sortie du plein écran ou lors de la révélation des boutons système. La marge Next/volume augmente de 3 pt ; le slider commence à x = 21 pt dans son groupe, soit 2 pt plus proche de l’icône qu’à l’étape précédente. Les chevrons du LCD se retirent par fondu seul, sans translation.

Le contrôle de disposition décale volontairement le bouton vert de 4 pt, vérifie sa remise en place, et contrôle la présence des deux animations bornées. Le contrôle de révélation plein écran exige également que les trois boutons visibles partagent le même centre vertical. Build de développement et intégration native sombre/clair validés, y compris plein écran, retour et réouverture. Un premier lancement clair n’a pas atteint l’état audio prêt ; la relance du scénario complet réussit. Le parcours sombre mesure une disposition synchrone médiane de 1,80 ms et un maximum de 3,47 ms sur la fenêtre de contrôle à 820–1 600 pt.

### Contrôles AppKit indépendants et cohérence inactive

Le centrage des instances possédées par le titlebar ne suffisait pas : le bouton vert restait soumis aux animations natives de révélation. Le header crée désormais ses trois contrôles avec `NSWindow.standardWindowButton(_:for:)` ; les instances du titlebar restent masquées. Les actions ferment, minimisent ou basculent la fenêtre en plein écran ; Option-clic sur le vert garde le zoom. Un test déplace l’instance native masquée et vérifie que le contrôle visible reste immobile. La révélation et le retrait utilisent un fondu de 160 ms ; les contrôles sont masqués à la fin du fondu pour libérer leur zone de clic. Les chevrons LCD utilisent eux aussi un fondu seul.

Le volume aligne les images SF sur leur `alignmentRect` typographique : à 10 pt, `speaker.wave.2.fill` mesure 14 × 10 pt et `speaker.wave.3.fill` 17 × 11 pt, ce qui rendait leur centrage par boîte instable. Le canal vide est un `NSVisualEffectView` under-window actif, avec le même voile `railGlassTint` que la sidebar. Remplissage et curseur restent au-dessus de ce verre.

La perte du focus atténue le titre et le sous-titre du LCD, les textes des cellules de sidebar et leurs grands titres à 45 %. Les horloges utilisent le gris inactif des commandes ; leur opacité de vue reste 1 pour préserver les fondus de contenu. Le temps restant se rapproche encore de 3 pt du bord droit et ne dessine plus de plaque au survol : seul son texte s’accentue. Les animations de texte avancent à 20 pt/s et se reposent 2,4 s, soit deux fois la pause précédente. Ces mises à jour suivent les notifications de fenêtre, sans horloge inactive.

### Pochettes, ancrage du haut-parleur et poignée de timeline

Les changements d’image utilisent un fondu de contenu de 200 ms sur la pochette seule. Une clé identique conserve l’image affichée ; deux absences d’image conservent le placeholder sans transition. Pendant le chargement d’une autre pochette, l’ancienne reste visible jusqu’au résultat. Le bouton Play conserve sa disponibilité pour lancer une sélection, tout en prenant la teinte désactivée de Back/Next lorsqu’aucune piste n’est chargée.

Le haut-parleur est désormais enregistré sur le rectangle gauche de son glyphe : une mesure alpha à résolution ×4, mémorisée pour chaque nom et taille de symbole, repère son ancrage. Les images normalisent leur `alignmentRect` pour éviter une seconde correction optique par NSImageView. La bouche garde le même x et son centre vertical coïncide avec celui des boutons système. Le dimensionnement initial du symbole de volume est lui aussi fixé à 10 pt.

Depuis le bouton vert du header, les feux restent visibles pendant toute la transition et leur fondu de 160 ms ne démarre qu’une fois la fenêtre réellement en plein écran, sur `didEnterFullScreenNotification` ; le masquage attend 200 ms. Les fondus utilisent le proxy d’animation AppKit. Le transport sans feux se rapproche de 4 pt du rail ; le volume inline peut grandir jusqu’à 117 pt et conserve sa réduction adaptative. Les largeurs sont arrondies au point pour garder le déplacement natif du curseur exactement cohérent avec les extrémités dessinées.

Au survol de la bande inférieure, une petite capsule opaque de 5 × 9 pt, au haut arrondi et au bas plat, apparaît par fondu de 180 ms et disparaît en 160 ms ; un anneau de masque de 1 px, décalé de 1,5 pt, l’entoure, et son ombre légère la détache de la piste et du remplissage. Après 400 ms de survol, sa couleur glisse vers la teinte accentuée en 180 ms, comme le bouton de volume, sans aucune variation de taille. Elle reste ancrée sur la position de lecture ; seul le scrub la déplace. Le temps flottant, lui, suit le pointeur et reste centré dessus, à 3 pt au-dessus. Son label appartient au header, au-dessus du LCD, afin de conserver ce centrage aux extrémités sans être coupé par le masque du panneau. Le label laisse passer les clics ; le slider accessible existant garde les gestes. Le mode Spectre conserve l’absence de temps flottant au survol.

## Vérification du polissage — 22 novembre 2026

- Build macOS de développement et build optimisé réussis ; `swift test` : 131 tests, 7 ignorés, aucun échec.
- `IPPM_CHECK_PLAYER=1` : clics Play/Pause animés, commandes externes et changement de piste sans transition, Option-Stop et retrait des infobulles ; volume opaque, extrémités/glissements et survol 7→9 pt ; plein écran et retour ; session système et arrêt des horloges.
- Prévisualisation réelle WAV 2 min, son coupé, en thèmes clair et sombre : composition Titre/Spectre/Waveform, pause/reprise, cache vidé pendant la lecture, plein écran, fermeture/réouverture. Captures de contrôle dans `/tmp/plr-composition-*.png` et `/tmp/plr-final-*.png` (artefacts locaux éphémères).
- Capture de la fenêtre native et ouverture du vrai popover AirPlay via Orca : plaque alignée à la file et sélecteur AVKit présent. Aucun appareil AirPlay externe ni touche média physique disponible pour cette vérification.
- Disposition synchrone de la fenêtre de contrôle à 820–1 600 pt : médiane 2,48 ms, maximum 3,47 ms dans le scénario clair ; mesure de cette fenêtre de test, sans prétendre mesurer les performances d’une grande bibliothèque.
- Limite distincte : `IPPM_CHECK_INTERACTIONS=1` s’arrête sur `NativeInteractionCheck.swift:390`, assertion du nombre d’éléments du menu des colonnes. Ce chemin n’est pas modifié par ce lot ; les contrôles ciblés du player passent. Le contrôle global ne doit pas être déclaré réussi.

### Finition transport, feux et timeline — 22 novembre 2026

La mesure d’encre à ×4 donne des ancrages bruts différents pour Play et Pause (9,75 contre 8,50 pt) : les centrer sur la boîte de l’image laissait 0,75 pt d’écart horizontal, visible comme une translation au changement de symbole. Le transport utilise maintenant le même canevas épinglé que le haut-parleur : chaque image est placée pour que le centre de son encre coïncide avec le centre du bouton, et le fondu conserve cette position. Mesure sur captures natives : les boîtes d’encre de Play et Pause partagent le même centre x (245,5 px en 2× ; 0,5 px d’écart vertical, soit 0,25 pt).

Le fondu des feux système attend désormais `didEnterFullScreenNotification` : `willEnterFullScreenNotification` laisse les trois boutons visibles et ne fait que réinitialiser l’état de révélation. Le bouton vert ne pré-masque plus les contrôles avant d’appeler `toggleFullScreen`. Le fondu de 160 ms et le masquage à 200 ms restent inchangés.

Le remplissage activé du volume partage la teinte inactive du reste des commandes : 35 % d’opacité (au lieu de 100 %) quand la fenêtre n’est plus la fenêtre clé, avec un fondu de 160 ms. Captures natives : le remplissage passe de 0,754 à 0,452 de luminance entre la fenêtre active et inactive.

La timeline garde sa capsule sur la position de lecture ; `hoverHandleRect` continue de suivre le pointeur pour l’infobulle. La capsule est opaque (5 × 9 pt, bas plat), son opacité est animée (180 ms à l’entrée, 160 ms à la sortie) et sa teinte accentuée arrive après 400 ms en 180 ms, sans grossir. Le même anneau de masque de 1 px à 1,5 pt entoure désormais le bouton de volume, dont la teinte de survol garde son délai et ses 180 ms. Captures natives : capsule de 10 × 18 px en 2× avec son anneau, blanche à 0,1 s puis teintée accent à 0,9 s sans changer de taille ; bouton de volume avec son masque.

Validation : build macOS de développement réussi ; `swift test` 131 tests, 7 ignorés, aucun échec. `IPPM_CHECK_PLAYER=1` : ancrages Play/Pause/Stop, curseur de timeline ancré à la lecture, teinte inactive du volume, puis limitation déjà connue du `PackageDropOverlayView` dans le contrôle de disposition (`WindowChromeMac.swift:143`). `IPPM_PLAYER_PREVIEW=qa-final …` : les feux restent visibles à l’entrée puis leur fondu est demandé après le plein écran ; la vérification de révélation des boutons système échoue ensuite sur l’absence du `NSToolbarFullScreenWindow` au moment de `didEnter` sous macOS 15.7.1 (même échec avec l’ancien ordre de fondu, donc indépendant de ce lot).

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

Validation du dernier complément : builds macOS de développement et optimisé, scénarios natifs clair/sombre, contrôle explicite de perte de focus (métadonnées, deux horloges et titres de sidebar), ainsi que réduction/fermeture/plein écran depuis les boutons visibles du header. Un premier contrôle de remplacement audio puis un essai de transfert du focus ont nécessité une relance du scénario ; la suite finale réussit.

Validation du complément pochettes/timeline : build de développement et scénario natif sombre réussis ; transitions entre images différentes, même image et deux placeholders vérifiées, ancrage du haut-parleur contrôlé, centrage de la capsule au bord droit capturé. La largeur fractionnaire initiale de 117,33 pt révélait une différence de déplacement dans NSSliderCell : les largeurs inline sont désormais entières, et les glissements à 0/25/50/75/100 % correspondent exactement au dessin. Les contrôles de CATransition lisent la clé canonique `kCATransition` (Core Animation ignore le nom personnalisé pour ce type d’animation). Le parcours sombre mesure une disposition médiane de 3,19 ms, maximum 4,89 ms dans la fenêtre de contrôle.

Le scénario clair et le build optimisé sont également validés ; les contrôles couvrent l’entrée et la sortie plein écran depuis le bouton vert, la réduction/fermeture/réouverture, l’absence de clignotement entre placeholders, les ancrages du haut-parleur et le centrage du temps sur la capsule. Le contrôle de volume restaure maintenant son niveau initial après les gestes synthétiques pour conserver la prévisualisation silencieuse.

## Polissage final du bandeau, recherche et haut-parleur — 25 novembre 2026

- **Haut-parleur et volume (`TransportSymbolMac.swift`, `ToolbarPlaybackButtonMac.swift`, `PlayerVolumeSliderMac.swift`)** : la trompette `speaker.fill` reste strictement immobile et centrée verticalement avec Play (`y = 16 pt` sur canevas `28 × 32 pt`, poids de rayon ×4 avec `rep.size = canvas`). Les ondes sont extraites en calques différentiels et animées en cascade (pas de `68 ms`, fondu de `115 ms` `.easeInEaseOut`). La barre oblique de sourdine se trace en `165 ms` `.easeOut` synchronisée avec un masque en demi-plan entre le corps plein et le corps coupé ; `applyTint` préserve l’état `slashShown` et les deux moitiés pendant le tracé. Le survol du haut-parleur utilise `glyphOnlyHover` et `customTrackingRect` (`x = 0..<17.5 pt`) pour ne pas s’illuminer au survol du curseur de volume et se réteindre en glissant hors zone. L’anneau de masque de `1 pt` coupe le canal vitré et le remplissage autour du bouton de volume et de la capsule de timeline.
- **Champ de recherche et recherche rapide (`PlayerSearchFieldMac.swift`, `SearchFieldMac.swift`, `WindowChromeMac.swift`, `Library.swift`)** : champ `170 × 24 pt` aligné au Pixel près avec `PlayerSearchFieldCell` (loupe centrée, marge texte jusqu’à `×`, recadrage par clipping sans points de suspension au repos). `FocusRingPrimerView` amorce la surface de focus AppKit une fois à l’ouverture pour éviter l’absence d’animation au premier `⌘F`. Le passage en arrière-plan préserve le focus et la sélection pour un retour par la barre d’outils, le Dock ou `⌘Tab`, mais le réinitialise si l’utilisateur clique dans le contenu hors barre d’outils. `FastSearch` précalcule des clés UTF-8 repliées (`Task.detached(priority: .utility)` dans `SearchCache` pour ≥ 256 pistes) avec rétrécissement incrémental et un rebond clavier léger de `60 ms` pour maintenir la fluidité de frappe sur les grandes bibliothèques.
- **Cohérence d’activation, plein écran et glisser-déplacer (`MacWindowLifecycle.swift`, `WindowChromeMac.swift`, `PlayerHeaderMac.swift`, `PlayerLCDContentMac.swift`, `PluginPlatformHelpers.swift`)** : `MacWindowLifecycle.visualActivationDidChange` unifie l’aspect inactif (rail, LCD, volume, recherche) lors des transitions Dock. `OpaqueExitBackdropView` élimine le flash de transparence à la sortie du plein écran. Les glisser-déplacer de fenêtre fonctionnent de manière fiable sur toute la barre (y compris boutons désactivés, pochette/titres LCD après seuil de `3 pt`, et `PackageDropOverlayView` placé sous `"playerHeader"` et transparent aux événements `leftMouseDragged`).
- **Spectre (`PlayerLCDModel.swift`, `LCDPlaybackPlotMac.swift`)** : montée progressive échelonnée par bande au démarrage (`beginRise`) et retombée décalée sans traînée des crêtes à la pause (`SpectrumIdleBarsView` / `SpectrumLitBarsView`).
