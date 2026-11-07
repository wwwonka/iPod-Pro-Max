# Rail de médias macOS

Le rail vertical à gauche (`MediaRailView` et `RailButton`, dans `iPod Pro Max/UI/MusicShell.swift`) est la référence de comportement pour les trois plateformes : la logique est fixée ici, sur Mac, puis portée sur Windows et Linux. Voir [[Interface verre et lecture]] pour la composition générale.

## Contenu et ordre

- De haut en bas : le bouton iPod quand un appareil est connecté, une ligne fine, les sections principales (Music, Podcasts, Audiobooks, Videos, Photos), une seconde ligne, les extras épinglés, puis le bouton « … ».
- Sans iPod, son bouton et son séparateur n'occupent aucune place. Une connexion insère le bouton depuis le haut du rail en 0,25 s (ease-out), fait apparaître le séparateur et décale les bibliothèques ; une déconnexion joue l'inverse en 0,2 s. `VolumeWatcher` déclenche l'animation sur un changement de périphérique : aucun timer ni polling au repos.
- Les icônes sont calibrées optiquement, pas seulement par leur boîte : Apple Music 15,5 pt ; Podcasts personnalisé 15 pt ; Photos et Games 17,5 pt avec une largeur maximale de 22 pt ; les autres 17 pt avec une largeur maximale de 21 pt. Videos utilise `film.stack`, Contacts `person`, Notes `long.text.page.and.pencil`. Voir [[Symboles personnalisés SVG]].
- Le bouton iPod porte le nom de l’iPod ouvert, ou du premier connecté (« iPod » à défaut). Il est dessiné à 17 pt, en monochrome (`preferringMonochrome`, macOS 13).
- Les sections principales se réordonnent en maintenant le clic et en glissant (au-delà de 4 pt de déplacement vertical). Un bouton ne change de place qu’à l’intérieur de son groupe (principales ou extras). Les autres glissent pour lui faire de la place (0,2 s, ease-out).
- L’ordre et les épinglages sont enregistrés dans `iPod Pro Max/Persistent Data/rail-order.json` (liste de noms), partagé par les trois OS. Sans dossier racine iPod, l’ordre n’est pas conservé. `RailOrder.normalized` remet les bibliothèques d’abord, puis les extras.
- Un clic droit dans le vide du rail propose « Reset Order » (ordre par défaut des bibliothèques et des extras épinglés, sans désépingler) ; le menu n’existe pas tant que l’ordre est celui par défaut.

## États d’un bouton

Machine à états : repos → survol (après 0,4 s) → appui → sélectionné.

| État | Plaque | Glyphe |
|---|---|---|
| Repos | aucune | `secondaryLabelColor` |
| Survol | voile blanc (noir en mode clair) à 6,5 % | `secondaryLabelColor` |
| Appui, ou menu ouvert depuis le bouton | voile à 13 % | blanc |
| Sélectionné | même voile que le survol (6,5 %) | blanc |
| Cible de dépôt d’un morceau | couleur d’accent pleine | blanc |
| Fenêtre inactive | atténué, pas de survol | atténué |

Les alphas viennent de mesures sur un `NSToolbarItem` natif en mode sombre ; le mode clair est une extrapolation non vérifiée.

- **Pas de clignotement** : un clic relâché dans le bouton le garde « allumé » (`activated`) jusqu’à ce que la sélection arrive.
- **Animations** : la plaque et la couleur du glyphe utilisent un fondu calme et presque symétrique, 0,18 s à l'entrée et 0,16 s à la sortie, tous deux en ease-in-out. Quitter une section ou choisir un extra laisse donc le highlight se dissiper au lieu de le couper net.
- **Forme** : le carré de 36 pt a un rayon continu de 8 pt, comme une plaque de `NSToolbarItem` compact plutôt qu'un bouton très arrondi.
- **Zone de réaction élargie** : 6 pt de chaque côté et 4 pt en haut et en bas du carré de 36 pt. Les 8 pt entre deux boutons appartiennent à l’un ou à l’autre, comme dans le Dock. Le carré dessiné ne change pas.
- Aucun timer au repos : le délai de survol est un `DispatchWorkItem` annulable.

## Noms de sections (pastille du Dock)

`RailLabel` remplace les tooltips. Mesures prises sur le Dock (captures en 2x) :

- Texte 14 pt régulier, pastille de 28 pt de haut, 15 pt de marge de chaque côté.
- Rayon de coin 5 pt, verre `hudWindow` découpé par une image de masque (le rayon d’un calque couperait le flou).
- Contour : 1 pt noir à 90 % au bord, puis 1 pt blanc à 18 % juste à l’intérieur, en bordures de calque (alignées sur les pixels). Pas d’ombre de fenêtre : son halo épaississait le noir dans les coins.
- La pastille commence 1 pt à droite du carré (qui finit 8 pt avant le bord du rail) : elle chevauche donc le rail de 7 pt. Elle vit dans sa propre fenêtre, au-dessus de tout.
- D’une icône nommée à la suivante : pas de pause, et le masquage est différé de 0,08 s pour qu’il n’y ait jamais d’intervalle sans nom. Elle disparaît d’un coup à l’appui et ne revient qu’après une sortie et un retour.
- Pas de survol ni de nom quand la fenêtre n’est pas la fenêtre active.

## Extras et menu « … »

- Le bouton « … » n’a pas de nom : le menu s’ouvre quand le pointeur reste dessus 0,4 s, et le bouton s’allume (état appui) en même temps.
- Le menu commence au même décalage horizontal de 1 pt que les pastilles `RailLabel`. C'est un panneau à nous (`ExtrasPopover`), pas un `NSMenu`, pour se comporter comme le menu d’une icône du Dock : il disparaît en fondu (0,15 s, ease-in) sur un clic hors du panneau (le clic est avalé), la touche Échap, ou quand le pointeur reste 0,25 s hors du panneau et du bouton. Le fondu du bouton démarre au même instant, y compris après le choix d'une section extra ; « … » n'est jamais le témoin persistant de la page choisie.
- Police 15 pt (13 pt par défaut) et icônes de 16 pt. Chaque ligne a une petite épingle à droite (`pin` / `pin.fill`, gris `secondaryLabelColor`, blanc sur la ligne survolée) : un clic l’épingle en bas des extras du rail (effet de symbole `appear`, macOS 14) ou la retire (`disappear`) ; les boutons du dessous glissent en même temps. Un clic droit sur un extra épinglé propose « Unpin from Sidebar ».
- Un minuteur de 1/30 s ne tourne que pendant que le panneau est ouvert (réaction à un événement, jamais au repos).
- Compromis : plus de navigation aux flèches ni de raccourcis de menu natifs dans ce panneau (seul Échap). Les menus de l’iPod à plusieurs appareils et les menus contextuels restent des `NSMenu`.

## Fenêtre, sidebar et recherche

- **Page iPod sans sidebar** (pour l’instant) : la colonne se masque d’un coup, sans glissement, dans la même passe de mise à jour que le décalage du contenu (appel depuis la mise à jour de la sidebar), pour éviter tout « jump cut ». Le choix ouvert/fermé de l’utilisateur n’est pas modifié ; le bouton de bascule de la barre d’outils est masqué sur ces pages. Au lancement, le masquage attend que la colonne soit construite.
- **Glissement de la sidebar** : ease-out à l’ouverture, ease-in à la fermeture (macOS, GTK et WinUI).
- **Recherche** : en dessous de 900 pt de large, le champ cède la place à un bouton loupe ; un clic redéploie le champ avec le focus, et il se replie quand il perd le focus vide. Le masquage d’un élément de barre d’outils demande macOS 15 ; avant, le champ reste affiché. Le seuil de 900 pt est un choix, non validé à l’œil.
- **⌘F** : intercepté dans la fenêtre pendant qu’une page a une recherche (le menu Édition n’affichait pas « Find… »), il déplie la loupe si besoin et active le champ.
- Le bouton « New Playlist… » du bas de la sidebar est retiré.

## À faire

- Porter le rail, les noms, l’ordre et les épinglages sur Windows et Linux (même machine à états, mêmes durées).
- Valider à l’œil : repli de la recherche, fondu de la couleur du glyphe, mode clair des voiles, coins de la pastille (un arrondi « continu » comme celui du Dock reste une piste).
- La page iPod n’a pas de sidebar ; une navigation du contenu de l’iPod viendra peut-être.
