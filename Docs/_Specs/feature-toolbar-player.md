# Spec — Lecteur dans la barre d'outils (PLR-1 à PLR-19)

Brief initial rédigé le 15 novembre 2026. L’implémentation et les ajustements ultérieurs sont décrits dans [[Lecteur et session média]] et [[LCD du lecteur]] ; les constats de revue sont dans [[Revue du lecteur novembre 2026]]. Les dispositions de départ ci-dessous sont conservées comme référence historique, notamment AirPlay intégré et le sélecteur de mode initial.

## 0. Cadre

### But

Remplacer le lecteur flottant du bas de la fenêtre par un lecteur intégré à la barre d'outils, dans l'esprit d'iTunes 10 et de Musique, et le relier au système d'exploitation (Control Center, touches média, AirPods).

### Périmètre

- **Implémentation : macOS seulement.** Windows et Linux gardent leur lecteur actuel jusqu'au portage.
- **Conçu pour le portage** : tout ce qui n'est pas du dessin natif (état du LCD, modes, activités, session média, analyse du spectre, cache) vit dans du code partagé, sans import AppKit. La couche macOS ne fait que dessiner et brancher les API système.
- Hors périmètre : mini-lecteur, minuterie de sommeil, teinte tirée de la pochette, égaliseur, portage Windows/Linux.

### Existant à connaître

| Élément | Emplacement | Remarque |
|---|---|---|
| Lecteur flottant actuel | `iPod Pro Max/UI/MusicPlayerMac.swift` (`NativePlayerDock`, `GlassPlayerView`, `WaveformView`) | À retirer sur macOS |
| État de lecture | `iPod Pro Max/Library/PlaybackController.swift` | Possède file, volume, aléatoire, répétition, waveform |
| Moteur | `iPod Pro Max/Platforms/AudioEngine.swift` (protocole `AudioEngine`, `AVPlayer` sur Mac) | Pas de réglage de vitesse aujourd'hui |
| File | `Sources/MediaKit/PlaybackQueue.swift` | Pas d'insertion ni de réordonnancement aujourd'hui |
| Waveform | `iPod Pro Max/Library/AudioWaveform.swift`, `MacWaveform.swift` | 1 024 pics, cache **en mémoire seulement** (`NSCache`, 4 Mo) |
| Barre d'outils | `iPod Pro Max/UI/WindowChromeMac.swift` (`MacChrome`, `NSToolbar` `unifiedCompact`, 44 pt) | Contient déjà le bouton de sidebar et la recherche |
| Paroles | `Sources/MediaKit/LyricsProvider.swift`, `Sources/iPodKit/LyricsTagFixup.swift` | Recherche LRCLIB depuis l'éditeur de métadonnées |
| Préférences | `iPod Pro Max/UI/SettingsView.swift` (onglet `advanced`), `Library/SettingsController.swift` | |
| Règles de lecture | `Docs/Interface/Interface verre et lecture.md` | Restent valides (file figée, Précédent après 3 s, répétition) |

### Contraintes permanentes (AGENTS.md)

- Fil principal réservé à l'interface. Décodage, FFT, écriture de cache et calcul de taille hors du fil principal, en QoS `.utility`.
- Aucun timer, aucune boucle au repos. Toute animation s'arrête en pause, fenêtre masquée ou mode inactif.
- Mesurer avant et après (voir section 7).

### Format des sous-tâches

Chaque sous-tâche donne : objectif, comportement utilisateur, règles d'interaction, états visuels, cas limites (comportement décidé) et questions ouvertes (à trancher par le propriétaire ; l'agent applique la valeur par défaut indiquée et le signale).

---

## 1. Barre d'outils

### PLR-1 – Disposition et retrait du lecteur flottant

**OBJECTIF**
Placer tout le lecteur dans une barre intégrée au contenu de 44 pt et supprimer le lecteur flottant sur macOS. La barre conserve les contrôles AppKit natifs, sans NSToolbar : le lecteur reste fixe en plein écran et aucune barre d’outils système vide ne doit se révéler au survol de la barre de menus.

**COMPORTEMENT UTILISATEUR**
De gauche à droite, après les feux : transport (PLR-2), volume (PLR-3), LCD centré avec AirPlay intégré (PLR-3 et PLR-4), bouton « À suivre » (PLR-12), recherche existante. Le lecteur est toujours présent, même sans lecture.

**RÈGLES D'INTERACTION**
- Le LCD est centré sur la fenêtre, pas sur l'espace restant, tant que la place le permet.
- La barre n'est pas personnalisable par l'utilisateur (comportement actuel conservé).
- Une zone vide de la barre continue de déplacer la fenêtre ; le LCD ne déplace pas la fenêtre.

**ÉTATS VISUELS**
- Proportions affinées avec le propriétaire : fenêtre initiale macOS de 1 240 × 700 pt, recherche de 170 pt, LCD en verre creusé de 41 pt de haut dans la toolbar de 44 pt, affleurant le bord supérieur avec 3 pt de marge inférieure, avec coins inférieurs de 3 pt, dégradés intérieurs, AirPlay réduit et contrôles de transport compacts (Play/Pause légèrement agrandi). Recherche native haute, bouton de sidebar retiré. Le verre reste translucide en arrière-plan ; seules les commandes changent de teinte.
- Fenêtre large : tout visible, LCD à sa largeur maximale (460 pt retenu).
- Fenêtre moyenne : le LCD rétrécit jusqu'à sa largeur minimale (280 pt proposé).
- Fenêtre étroite : disparaissent dans l'ordre le curseur de volume (reste un bouton qui ouvre un curseur en popover), puis la recherche se replie en loupe (comportement de repli existant).
- Fenêtre inactive : contrôles estompés comme le reste de la barre.

**CAS LIMITES**
- Plein écran et sidebar masquée : même disposition, le LCD reste centré.
- Fermer le lecteur n'existe plus : arrêter la lecture se fait en vidant la file (PLR-12) ou en quittant.

**QUESTIONS OUVERTES**
- Largeurs minimale et maximale du LCD (par défaut 280 et 460 pt).
- Faut-il une commande « Arrêter » explicite (menu Commandes) qui libère le moteur et la file ? Par défaut : oui, dans le menu seulement.

### PLR-2 – Transport

**OBJECTIF**
Précédent, lecture/pause, suivant, toujours accessibles.

**COMPORTEMENT UTILISATEUR**
Trois boutons compacts en SF Symbols : `backward.fill`, `play.fill` / `pause.fill`, `forward.fill`. Lecture/pause est légèrement plus grand. Aléatoire et répétition ne sont pas ici : ils sont dans le popover « À suivre » et le menu Commandes.

**RÈGLES D'INTERACTION**
- Clic : action. Règles inchangées (Précédent repart au début après 3 s, Suivant ignore la répétition de piste).
- Appui maintenu sur Précédent ou Suivant : recul ou avance rapide, tant que le bouton est tenu.
- Raccourcis clavier existants conservés ; Espace bascule lecture/pause quand aucun champ de texte n'a le focus.

**ÉTATS VISUELS**
- Aucune file : lecture/pause actif (relance la dernière sélection si elle existe, sinon inactif), précédent et suivant inactifs.
- Lecture : icône pause. Pause : icône lecture.
- Chargement : aucun changement d'icône, le LCD indique le chargement.
- Survol et pression : états natifs des boutons de barre d'outils.

**CAS LIMITES**
- Dernière piste sans répétition : Suivant arrête la lecture, le LCD revient à l'état de repos.
- Clics rapides répétés : seule la dernière piste demandée est chargée (le compteur de génération existant le garantit).

**QUESTIONS OUVERTES**
- Lecture sans file : que lance le bouton ? Par défaut : la sélection de la vue courante, sinon rien.
- Vitesse de l'avance rapide à l'appui maintenu (par défaut : sauts de 5 s toutes les 250 ms pendant l'appui, sans timer hors appui).

### PLR-3 – Volume et AirPlay

**OBJECTIF**
Régler le volume de l'app et choisir la sortie audio.

**COMPORTEMENT UTILISATEUR**
Un curseur compact avec une icône de haut-parleur. Le bouton AirPlay natif (`AVRoutePickerView`) est intégré au bord droit du LCD.

**RÈGLES D'INTERACTION**
- Glisser ou cliquer sur le curseur : volume immédiat.
- Défilement au-dessus du curseur : ajuste le volume.
- Clic sur l'icône : coupe ou rétablit le son, en retenant le volume précédent.
- Le volume reste un réglage de session, comme aujourd'hui.

**ÉTATS VISUELS**
- Icône à trois niveaux selon le volume, barrée en sourdine.
- AirPlay actif : bouton teinté (comportement natif).

**CAS LIMITES**
- Le volume réglé depuis Control Center est celui du système, pas celui de l'app : aucune synchronisation.
- Perte de la sortie AirPlay : macOS rebascule seul ; la lecture se met en pause si le système le signale.

**QUESTIONS OUVERTES**
- Mémoriser le volume entre les sessions ? Par défaut : non (règle actuelle).

---

## 2. Écran LCD

Hauteur utile d'environ 32 pt dans une barre de 44 pt : deux lignes de texte au maximum.

### PLR-4 – Conteneur et états généraux

**OBJECTIF**
Un écran unique, hybride : contenant moderne en verre, contenu avec des touches rétro.

**COMPORTEMENT UTILISATEUR**
Rectangle arrondi en verre natif (`NSVisualEffectView`), typographie système, thème clair et sombre. À gauche une petite icône de mode (PLR-10), à droite la flèche de retour (PLR-5) ou les flèches d'activité (PLR-11). Le centre affiche le mode courant.

**RÈGLES D'INTERACTION**
- Le contenu change par fondu court (150 ms). Avec « Réduire les animations », changement sans fondu.
- Le LCD est accessible à VoiceOver : il annonce titre, artiste, position et le mode courant.

**ÉTATS VISUELS**

| État | Affichage |
|---|---|
| Repos, aucun iPod | Écran vide |
| Repos, iPod branché | Nom de l'iPod et espace libre |
| Chargement d'une piste | Titre affiché, progression vide, temps « --:-- » |
| Lecture | Mode choisi, animé si le mode l'exige |
| Pause | Mode choisi, figé, texte légèrement estompé |
| Erreur de lecture | Message sur une ligne, icône d'avertissement ; un clic sur lecture relance |
| Activité en cours | Voir PLR-11 |

**CAS LIMITES**
- Piste sans pochette : pochette générique existante.
- Texte trop long : défilement horizontal lent, seulement au survol ou une fois à l'arrivée de la piste, jamais en continu.
- Fenêtre masquée ou minimisée : aucun redessin.

**QUESTIONS OUVERTES**
- Le défilement du texte long : au survol seulement, ou une fois à chaque nouvelle piste ? Par défaut : une fois à l'arrivée, puis au survol.
- Plusieurs iPod branchés au repos : lequel afficher ? Par défaut : le dernier sélectionné dans la sidebar.

### PLR-5 – Mode Titre

**OBJECTIF**
Le mode par défaut, équivalent de l'affichage de Musique.

**COMPORTEMENT UTILISATEUR**
Pochette carrée à gauche. Ligne 1 : titre. Ligne 2 : artiste — album (podcast : émission — date ; livre audio : livre — chapitre). Temps écoulé à gauche, temps restant à droite, fine barre de progression en bas.

**RÈGLES D'INTERACTION**
- Clic sur le temps de droite : bascule restant / durée totale ; choix mémorisé.
- Clic sur le titre ou sur la flèche ↩ à droite : sélectionne et fait défiler jusqu'à la piste dans la vue d'où elle a été lancée.
- Clic sur la pochette : même effet que ↩.
- Bouton « ••• » au survol : menu contextuel de la piste (PLR-19).

**ÉTATS VISUELS**
- Survol : apparition de « ••• » et épaississement de la barre de progression.
- Pause : texte estompé, barre figée.

**CAS LIMITES**
- Métadonnées absentes : nom de fichier en titre, ligne 2 vide.
- La piste a été retirée de la bibliothèque pendant la lecture : ↩ est inactive.
- La vue d'origine est filtrée par une recherche : ↩ efface la recherche avant de révéler la piste.

**QUESTIONS OUVERTES**
- ↩ doit-elle ramener à la vue d'origine ou à « Toutes les chansons » ? Par défaut : vue d'origine.

### PLR-6 – Progression et scrub (commun à Titre et Waveform)

**OBJECTIF**
Se déplacer dans la piste avec précision.

**COMPORTEMENT UTILISATEUR**
On clique ou on glisse sur la progression. Au survol, une bulle montre le temps visé. Les chapitres des podcasts et livres audio apparaissent comme des encoches.

**RÈGLES D'INTERACTION**
- Clic : saut immédiat.
- Glisser : la position visée suit le pointeur ; le saut réel a lieu au relâchement. Les temps affichés suivent le pointeur pendant le geste.
- Échap pendant un glisser : annule.
- Défilement horizontal au trackpad au-dessus du LCD : avance ou recule proportionnellement, saut appliqué à la fin du geste.
- Près d'une encoche de chapitre (6 pt), le pointeur s'y aimante ; la bulle montre le nom du chapitre.

**ÉTATS VISUELS**
- Repos : barre fine. Survol : barre épaisse, bulle de temps. Glisser : poignée visible.
- Chargement ou durée inconnue : barre inactive, pas de bulle.

**CAS LIMITES**
- Saut au-delà de la fin : borné à la durée (comportement existant de `seek`).
- Scrub en pause : la position change, la lecture ne reprend pas.
- Changement de piste pendant un glisser : le geste est annulé.

**QUESTIONS OUVERTES**
- Retour haptique sur trackpad Force Touch au passage d'un chapitre ? Par défaut : non en version 1.

### PLR-7 – Mode Spectre

**OBJECTIF**
Retrouver l'égaliseur visuel d'iTunes 10.7.

**COMPORTEMENT UTILISATEUR**
Deux blocs de barres verticales segmentées, avec un trait de maintien des pics qui retombe lentement. Titre et temps disparaissent ; la fine barre de progression reste en bas.

**RÈGLES D'INTERACTION**
- Les données viennent du spectre pré-calculé (PLR-16), indexé par la position de lecture.
- Animation à 30 images/s au plus, liée au rafraîchissement de l'écran, active seulement si : lecture en cours, fenêtre visible, mode Spectre affiché.
- Le survol affiche brièvement le titre en surimpression.

**ÉTATS VISUELS**
- Spectre pas encore prêt : grille de segments éteints, puis apparition en fondu.
- Lecture : barres animées. Pause : barres figées à leur dernière valeur, pics retombés.
- « Réduire les animations » : cadence abaissée à 10 images/s, sans retombée des pics.

**CAS LIMITES**
- Analyse impossible (format non décodable) : segments éteints, pas d'erreur.
- Saut dans la piste : les barres prennent directement la valeur de la nouvelle position.
- Flux en deux canaux : gauche et droite dans les deux blocs ; mono : même signal dans les deux.

**QUESTIONS OUVERTES**
- Les deux blocs représentent-ils gauche/droite (comme iTunes) ou une seule plage de fréquences étalée ? Par défaut : gauche/droite.
- Nombre de barres par bloc (par défaut 16).

### PLR-8 – Mode Waveform

**OBJECTIF**
Voir la forme de la piste et s'y déplacer.

**COMPORTEMENT UTILISATEUR**
La waveform occupe toute la largeur. La partie écoutée est en couleur d'accent, le reste estompé. Temps écoulé et restant aux extrémités.

**RÈGLES D'INTERACTION**
- Scrub selon PLR-6, directement sur la waveform.
- Réutilise les 1 024 pics existants ; aucune nouvelle analyse.

**ÉTATS VISUELS**
- Waveform pas encore prête : barre de progression simple, remplacée en fondu.
- Lecture : la limite écoutée avance au rythme des événements de progression du moteur, sans timer propre.

**CAS LIMITES**
- Piste très longue (livre audio de plusieurs heures) : les 1 024 pics suffisent ; les encoches de chapitre restent lisibles.
- Analyse échouée : repli sur la barre simple.

**QUESTIONS OUVERTES**
- Aucune.

### PLR-9 – Mode Paroles

**OBJECTIF**
Afficher la ligne chantée en cours.

**COMPORTEMENT UTILISATEUR**
La ligne courante au centre ; la suivante, plus petite et estompée, en dessous. Les lignes glissent verticalement au changement.

**RÈGLES D'INTERACTION**
- Source : paroles synchronisées déjà présentes dans les tags ou la bibliothèque. **Aucune requête réseau pendant la lecture.**
- Le changement de ligne est planifié à l'horodatage de la ligne suivante (une seule échéance à la fois, annulée en pause) ; pas d'interrogation périodique.
- Clic sur une ligne : aucun effet en version 1.

**ÉTATS VISUELS**
- Avant la première ligne et dans les passages instrumentaux : « ♪ ».
- Pause : ligne figée, estompée.

**CAS LIMITES**
- Paroles non synchronisées ou absentes : le LCD affiche le mode Titre ; le mode Paroles reste mémorisé et revient à la prochaine piste qui en possède.
- Horodatages désordonnés ou invalides : traités comme absents.
- Saut dans la piste : la ligne correspondant à la nouvelle position s'affiche sans animation.

**QUESTIONS OUVERTES**
- Proposer de chercher les paroles (LRCLIB) depuis le LCD quand elles manquent ? Par défaut : non, cela reste dans l'éditeur de métadonnées.
- Afficher les paroles non synchronisées en défilement manuel ? Par défaut : non.

### PLR-10 – Changement de mode

**OBJECTIF**
Passer d'un mode à l'autre d'un geste, comme le petit triangle d'iTunes.

**COMPORTEMENT UTILISATEUR**
Un clic sur l'icône de gauche passe au mode suivant : Titre → Spectre → Waveform → Paroles → Titre. Un clic droit ouvre la liste des modes.

**RÈGLES D'INTERACTION**
- L'icône représente le mode courant.
- Le mode est mémorisé entre les sessions (préférence portable).
- Un mode indisponible pour la piste courante (Paroles sans paroles) est sauté dans le cycle.

**ÉTATS VISUELS**
- Survol : icône accentuée, info-bulle avec le nom du mode.
- Repos sans lecture : icône estompée, clic sans effet.

**CAS LIMITES**
- Changement de mode pendant une analyse en cours : le mode s'affiche dans son état « pas encore prêt ».

**QUESTIONS OUVERTES**
- Ordre du cycle (par défaut celui indiqué).

### PLR-11 – Écran d'état des activités

**OBJECTIF**
Faire du LCD l'afficheur de toute activité longue de l'app, comme iTunes pendant une synchronisation.

**COMPORTEMENT UTILISATEUR**
Pendant un import, une synchronisation d'iPod ou un transcodage, le LCD montre une ligne de titre (« Synchronisation de l'iPod de Julien »), une ligne de détail (« Copie de 12 sur 300 : Titre »), une barre de progression et un bouton ✕ pour annuler. Deux petites flèches à droite passent d'une activité à l'autre et à la lecture en cours.

**RÈGLES D'INTERACTION**
- Une activité qui démarre prend l'affichage. L'utilisateur peut revenir à la lecture avec les flèches ; son choix tient jusqu'à la fin de cette activité.
- Fin d'une activité : message de fin pendant 3 s (« Synchronisation terminée »), puis retour à la lecture ou au repos. Échéance unique, pas de timer récurrent.
- Mise à jour du texte et de la progression à la cadence existante d'environ 500 ms.
- ✕ demande une confirmation seulement pour la synchronisation d'iPod.
- Le modèle des activités (titre, détail, fraction, annulable) est partagé et alimenté par les opérations existantes ; le LCD ne fait que l'afficher.

**ÉTATS VISUELS**

| État | Affichage |
|---|---|
| Progression connue | Barre remplie, compte « n sur m » |
| Progression inconnue | Barre indéterminée animée, arrêtée si la fenêtre est masquée |
| Terminée | Coche et message, 3 s |
| Échec | Icône d'avertissement et message ; reste affiché jusqu'au clic |
| Plusieurs activités | Points indicateurs sous les flèches |

**CAS LIMITES**
- Activité qui se termine en moins d'une seconde : pas d'affichage intermédiaire, seulement le message de fin.
- Lecture qui démarre pendant une activité affichée : l'activité reste à l'écran, la lecture est accessible par les flèches.
- Activité en échec pendant qu'une autre démarre : l'échec reste dans la liste jusqu'à son acquittement.
- iPod débranché en cours de synchronisation : état d'échec avec le message existant.

**QUESTIONS OUVERTES**
- Quelles opérations exactes sont des activités en version 1 ? Par défaut : import de fichiers, synchronisation iPod, transcodage, téléchargement de podcasts.
- Une activité doit-elle toujours prendre l'affichage, ou seulement si aucune lecture n'est en cours ? Par défaut : toujours, avec retour possible.
- Les indicateurs de progression existants ailleurs dans l'interface sont-ils retirés ? Par défaut : conservés en version 1.

---

## 3. File d'attente

### PLR-12 – Popover « À suivre »

**OBJECTIF**
Voir et modifier la file sans quitter la vue courante.

**COMPORTEMENT UTILISATEUR**
Le bouton liste, à droite du LCD, ouvre un popover : en tête la piste en cours, puis les pistes à venir avec pochette, titre, artiste et durée. En haut : aléatoire, répétition, « Effacer ». Dans les listes de la bibliothèque, le menu contextuel gagne « Lire ensuite » et « Ajouter à la file ».

**RÈGLES D'INTERACTION**
- Double-clic sur une piste : saute à cette piste.
- Glisser une ligne : réordonne. Glisser des pistes depuis la bibliothèque dans le popover : insère à l'endroit du dépôt.
- Suppr ou glisser hors du popover : retire de la file.
- « Lire ensuite » insère juste après la piste en cours ; « Ajouter à la file » ajoute à la fin.
- « Effacer » vide les pistes à venir, garde la piste en cours.
- Liste virtualisée ; les pochettes ne sont demandées que pour les lignes visibles.

**ÉTATS VISUELS**
- File vide : texte « Aucune piste à suivre ».
- Aléatoire actif, répétition (file / piste) : boutons teintés, icône de répétition à deux variantes.
- Bouton « À suivre » de la barre : teinté quand le popover est ouvert, inactif sans file.

**CAS LIMITES**
- Aléatoire activé puis réordonnancement manuel : l'ordre manuel devient l'ordre aléatoire courant ; désactiver l'aléatoire rétablit l'ordre d'origine avec les insertions à la suite de la piste en cours.
- « Lire ensuite » sur une piste déjà dans la file : elle est déplacée, pas dupliquée (la file déduplique par identifiant).
- « Lire ensuite » sans lecture en cours : démarre la lecture de la sélection.
- File de plusieurs milliers de pistes : ouverture immédiate, défilement fluide.

**QUESTIONS OUVERTES**
- Autoriser le même morceau plusieurs fois dans la file ? Par défaut : non (règle actuelle de `PlaybackQueue`).
- Afficher l'historique des pistes écoutées dans le popover ? Par défaut : non en version 1.
- La file est-elle conservée entre les sessions ? Par défaut : non (règle actuelle).

---

## 4. Intégration au système

### PLR-13 – Session média partagée

**OBJECTIF**
Un seul point de sortie de l'état de lecture vers l'OS, identique pour les trois plateformes.

**COMPORTEMENT UTILISATEUR**
Invisible. C'est ce qui permet à l'OS d'afficher et de commander la lecture.

**RÈGLES D'INTERACTION**
- Un protocole de session média dans `MediaKit` reçoit de `PlaybackController` : titre, artiste, album, pochette, durée, position, vitesse, état (lecture, pause, arrêt), disponibilité de précédent et suivant.
- Il remonte des commandes : lecture, pause, bascule, suivant, précédent, saut à une position, saut relatif.
- Publication sur événement seulement (changement de piste, lecture, pause, saut, changement de vitesse). La position n'est jamais publiée en continu : l'OS l'extrapole à partir de la position et de la vitesse.
- La session n'est créée qu'à la première lecture, comme le moteur.
- Une implémentation simulée permet les tests.

**ÉTATS VISUELS**
- Sans objet.

**CAS LIMITES**
- Commande reçue sans file : ignorée.
- Commandes en rafale (touche tenue) : traitées par les mêmes règles que les boutons, sans chargements superflus.

**QUESTIONS OUVERTES**
- Aucune.

### PLR-14 – Branchement macOS : Now Playing et commandes distantes

**OBJECTIF**
Faire apparaître le lecteur dans Control Center, sur l'écran verrouillé, et répondre aux touches média et aux écouteurs.

**COMPORTEMENT UTILISATEUR**
La piste en cours apparaît dans le module « À l'écoute » de Control Center et de la barre des menus, avec pochette, titre, artiste et barre de progression déplaçable. Les touches F7/F8/F9, les AirPods (pincement, retrait d'une oreille) et les casques Bluetooth commandent l'app.

**RÈGLES D'INTERACTION**
- `MPNowPlayingInfoCenter` pour les métadonnées et l'état ; `MPRemoteCommandCenter` pour les commandes.
- Commandes activées : lecture, pause, bascule, suivant, précédent, changement de position. Pour podcasts et livres audio : saut de 15 s en arrière et 30 s en avant à la place de précédent/suivant.
- La pochette est fournie à la taille demandée par le système, décodée hors du fil principal.
- À la fin de la file ou à l'arrêt : l'état passe à arrêté et les informations sont retirées.

**ÉTATS VISUELS**
- Dans Control Center : lecture, pause, absence (rien quand la file est vide).

**CAS LIMITES**
- Une autre app prend la main (Musique, Spotify) : les touches média vont à la dernière app ayant joué ; aucun contournement.
- Retrait d'un AirPod : macOS envoie pause ; la remise en place envoie lecture.
- Piste sans pochette : pochette générique fournie.
- App en arrière-plan ou fenêtre fermée avec lecture en cours : les commandes fonctionnent.

**QUESTIONS OUVERTES**
- Sauts de 15/30 s pour les podcasts : ces valeurs conviennent-elles ? Par défaut : 15 et 30 s.
- Fermer la fenêtre pendant la lecture : la lecture continue-t-elle ? Par défaut : comportement actuel de l'app inchangé.

### PLR-15 – Menu du Dock

**OBJECTIF**
Commander la lecture depuis l'icône du Dock.

**COMPORTEMENT UTILISATEUR**
Clic droit sur l'icône : titre et artiste en cours (inactifs), puis Lecture/Pause, Suivant, Précédent, sous-menus Aléatoire et Répétition.

**RÈGLES D'INTERACTION**
- Le menu est construit à la demande, à son ouverture.

**ÉTATS VISUELS**
- Sans lecture : seule l'entrée Lecture, inactive s'il n'y a rien à lancer.
- Aléatoire et répétition cochés selon l'état.

**CAS LIMITES**
- Titre très long : tronqué au milieu.

**QUESTIONS OUVERTES**
- Aucune.

---

## 5. Données et cache

### PLR-16 – Spectre pré-calculé

**OBJECTIF**
Fournir les données du mode Spectre sans traitement audio en temps réel, de façon identique sur les trois plateformes.

**COMPORTEMENT UTILISATEUR**
Invisible. À la première lecture d'une piste, le spectre apparaît après un court délai ; aux lectures suivantes, immédiatement.

**RÈGLES D'INTERACTION**
- Calcul lancé au chargement d'une piste, avec l'analyse de waveform, dans le même passage de décodage si possible. QoS `.utility`, une analyse à la fois, annulée au changement de piste.
- Format : une suite d'images, chaque image contenant l'énergie par bande sur un octet, pour les canaux gauche et droit. Valeurs de départ : 20 images/s, 16 bandes par canal, bandes réparties de façon logarithmique.
- L'affichage interpole entre deux images.
- Le résultat est écrit dans le cache disque (PLR-17) ; rien n'est écrit sur l'iPod ni dans la bibliothèque.
- Le format de fichier porte un numéro de version ; une version inconnue est recalculée.

**ÉTATS VISUELS**
- Sans objet (voir PLR-7).

**CAS LIMITES**
- Fichier très long (livre audio de 10 h) : l'analyse ne doit pas retenir tout le fichier décodé en mémoire ; écriture au fil de l'eau.
- Fichier modifié (taille ou date) : la clé change, l'ancien fichier de cache est évincé au prochain ménage.
- Fichier sur un iPod ou un volume lent : même traitement ; l'annulation doit être rapide au changement de piste.
- Changement de piste avant la fin de l'analyse : résultat partiel jeté.

**QUESTIONS OUVERTES**
- Cadence et nombre de bandes définitifs, après mesure (section 7).
- Analyser en avance la piste suivante de la file pour supprimer le délai ? Par défaut : non en version 1.
- Durée au-delà de laquelle on n'analyse pas (livres audio) ? Par défaut : pas de spectre au-delà de 2 h.

### PLR-17 – Dossier temporaire et cache disque

**OBJECTIF**
Garder les données dérivées dans un seul dossier clairement nommé du répertoire temporaire, pour ne laisser aucun résidu permanent sur un ordinateur.

**COMPORTEMENT UTILISATEUR**
Invisible en usage normal. Si le dossier est vidé par l'OS ou par l'utilisateur, tout continue de fonctionner.

**RÈGLES D'INTERACTION**
- Emplacement : `$TMPDIR/iPod Pro Max/` sur macOS. Prévu : `%TEMP%\iPod Pro Max\` sur Windows, `$XDG_RUNTIME_DIR` ou `/tmp/iPod Pro Max-<uid>/` sur Linux.
- Un sous-dossier par catégorie : `Spectrum/`, `Waveforms/`, `Scratch/` (fichiers de travail éphémères).
- Les waveforms, aujourd'hui en mémoire seulement, gagnent un cache disque dans `Waveforms/` ; le cache mémoire reste devant.
- Les fichiers temporaires existants posés à la racine du répertoire temporaire (`ippm-art-…`, `poster-…`) passent dans `Scratch/`.
- Noms de fichiers : empreinte du chemin, de la taille et de la date du fichier source. Aucun titre ni chemin en clair.
- Plafond de taille global (200 Mo par défaut) ; éviction des fichiers les moins récemment utilisés.
- Ménage : une passe au lancement, en arrière-plan, qui vide `Scratch/`, applique le plafond et supprime les versions de format obsolètes. Une passe à la fermeture pour les catégories réglées sur « effacer en quittant » (PLR-18). Aucun timer.
- Écritures atomiques (fichier temporaire puis renommage).

**ÉTATS VISUELS**
- Sans objet.

**CAS LIMITES**
- Dossier supprimé pendant que l'app tourne : recréé à la prochaine écriture, sans erreur visible.
- Disque plein ou écriture refusée : l'app continue avec le cache mémoire seul.
- Deux instances de l'app : chacune tolère les fichiers de l'autre ; `Scratch/` n'est vidé que des fichiers plus vieux que le lancement.
- App quittée de force : pas de ménage de fermeture ; le ménage du lancement suivant rattrape.

**QUESTIONS OUVERTES**
- Les autres caches existants (vignettes de pochettes, photos d'artistes) rejoignent-ils ce dossier ? Par défaut : non en version 1, à inventorier.
- Plafond par défaut (200 Mo proposé).

### PLR-18 – Préférences avancées : fichiers temporaires

**OBJECTIF**
Donner à l'utilisateur le contrôle sur ce que l'app garde sur l'ordinateur.

**COMPORTEMENT UTILISATEUR**
Dans l'onglet Advanced des préférences, une section « Fichiers temporaires » :
- une ligne par catégorie (Spectres, Waveforms) avec sa taille et un choix « Conserver entre les sessions » ou « Effacer en quittant » ;
- la taille totale et le plafond réglable ;
- un bouton « Vider le cache » ;
- un bouton « Afficher dans le Finder ».

**RÈGLES D'INTERACTION**
- Les tailles sont calculées à l'ouverture de la section, hors du fil principal, et après un vidage. Pas de rafraîchissement périodique.
- « Vider le cache » agit immédiatement, sans confirmation (tout est recalculable), y compris pendant la lecture.
- Abaisser le plafond déclenche une éviction immédiate.
- Par défaut : tout est conservé entre les sessions.
- Ces réglages sont des préférences portables, avec les autres.

**ÉTATS VISUELS**
- Calcul en cours : « Calcul… » à la place de la taille.
- Cache vide : « Aucun fichier », bouton de vidage inactif.
- Après vidage : tailles à zéro.

**CAS LIMITES**
- Vidage pendant qu'une analyse écrit : l'écriture en cours aboutit ou échoue sans erreur visible ; le fichier pourra réapparaître.
- Le spectre de la piste en cours reste en mémoire après un vidage : l'affichage ne se fige pas.

**QUESTIONS OUVERTES**
- Faut-il un réglage unique « Ne rien laisser sur cet ordinateur » qui bascule toutes les catégories ? Par défaut : non, les choix par catégorie suffisent.
- Libellés définitifs (l'onglet est en anglais aujourd'hui ; suivre la langue de l'interface existante).

---

## 6. Compléments

### PLR-19 – Menu « ••• » et vitesse de lecture

**OBJECTIF**
Regrouper les actions sur la piste en cours et régler la vitesse des contenus parlés.

**COMPORTEMENT UTILISATEUR**
Le menu « ••• » du LCD propose : Afficher dans la bibliothèque, Lire les informations (éditeur de métadonnées), Favori, et pour les podcasts et livres audio un sous-menu Vitesse (0,75×, 1×, 1,25×, 1,5×, 2×).

**RÈGLES D'INTERACTION**
- La vitesse s'applique immédiatement, sans changement de hauteur de la voix.
- Elle est transmise à la session média (PLR-13) pour que l'OS extrapole correctement la position.
- Demande une capacité de vitesse sur le protocole `AudioEngine` ; les moteurs Windows et Linux peuvent la laisser sans effet jusqu'au portage.

**ÉTATS VISUELS**
- Vitesse différente de 1× : petit indicateur « 1,5× » à côté du temps dans le LCD.

**CAS LIMITES**
- Passage d'un podcast à une chanson : la vitesse revient à 1× pour la musique ; elle est retenue pour le prochain contenu parlé de la session.
- Spectre et paroles : indexés sur la position, donc corrects à toute vitesse.

**QUESTIONS OUVERTES**
- La vitesse est-elle retenue par émission, par type de contenu, ou pas du tout ? Par défaut : par type de contenu, pour la session.
- Cette sous-tâche peut sortir de la version 1 si le périmètre doit être réduit.

---

## 7. Vérification

L'agent indique, avant de commencer chaque sous-tâche, comment il la vérifiera.

**Automatique**
- `swift test` : nouvelles opérations de la file (insertion, déplacement, retrait, interaction avec l'aléatoire), modèle du LCD (cycle des modes, repli Paroles vers Titre, saut des modes indisponibles), modèle des activités (priorité, fin, échec), session média simulée (événements publiés, aucune publication continue), cache (clé, plafond, éviction, ménage, versions).
- `IPPM_CHECK_INTERACTIONS=1` : étendre au lecteur de barre d'outils avec le moteur simulé.
- `IPPM_CHECK_AUDIO=<court WAV silencieux>` : la session reçoit durée, lecture, pause, saut et fin.

**Manuel sur Mac**
- Control Center et barre des menus : pochette, titre, progression, déplacement.
- Touches média, AirPods (pincement, retrait), casque Bluetooth.
- Menu du Dock.
- Fenêtre redimensionnée de la largeur maximale à la minimale ; plein écran ; thèmes clair et sombre ; « Réduire les animations ».
- Vidage du dossier temporaire pendant la lecture.

**Mesures à consigner dans `Docs/`**
- Temps d'analyse du spectre et taille du fichier pour des pistes de 3 min, 10 min et 2 h, sur la bibliothèque de référence.
- Charge processeur en lecture pour chaque mode du LCD, et en pause : elle doit être nulle en pause et fenêtre masquée.
- Coût de disposition de la barre d'outils au redimensionnement.

## 8. Ordre conseillé

1. PLR-13, PLR-14 (session média : valeur immédiate, indépendante de l'interface).
2. PLR-1, PLR-2, PLR-3, PLR-4, PLR-5, PLR-6 (lecteur de barre d'outils utilisable, retrait du lecteur flottant).
3. PLR-17, PLR-18 (cache disque et préférences).
4. PLR-16, PLR-7, PLR-8, PLR-10 (spectre, waveform, changement de mode).
5. PLR-11 (écran d'état).
6. PLR-12 (À suivre).
7. PLR-9, PLR-15, PLR-19.

## 9. Portage ultérieur (rappel, hors périmètre)

- Session média : SystemMediaTransportControls sur Windows, MPRIS sur Linux.
- Dessin du LCD : couche native par plateforme, sur le même modèle partagé.
- Analyse du spectre : le décodage passe déjà par ffmpeg hors macOS pour les waveforms ; même voie.
