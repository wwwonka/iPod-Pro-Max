# Refonte verre macOS

Journal de la refonte de l'interface sur la branche `codex/interface-glass` (macOS d'abord ; Windows et Linux doivent reprendre le même aspect avec leurs composants natifs). Plan d'origine : phases 0 à 5 dans le plan de la refonte. Mesures du 7 novembre 2026, MacBook Pro M1 Max, macOS 15.7.1.

## Cadre de fenêtre

- Fenêtre en verre : barre du haut de 52 pt (`titleBarHeight`) et rail vertical de 52 pt (`mediaRailWidth`). Constantes dans `UI/WindowChrome.swift`, partagées avec GTK et WinUI.
- La vue principale est un panneau arrondi flottant : translucide (`FrostedSurface`, teinte 0,7), marge de 3 pt à droite et en bas (`floatingPanelMargin`), rayon concentrique avec la fenêtre (`floatingPanelRadius` = rayon de la fenêtre − marge ; 26 pt dès macOS 26, 16 avant).
- Liseré de 1 pt en dégradé (`PanelRim`, NSGradient, tracé pair-impair) autour du panneau, à environ 50 % d'opacité. Il est posé au niveau de la zone, pas par vue, et attend que la mise en page soit stable (colonne > 150 pt, zone > 500 pt, bord gauche à la largeur du rail) pour ne pas toucher le rail au lancement.
- Barre d'état du bas supprimée sauf pendant un transfert.

## Rail vertical

- Boutons d'icônes (iPod en bas, avec cible de dépôt ; bibliothèques ; bouton « … » ouvrant un menu des sections cachées : jeux, contacts, calendriers, notes, fichiers).
- Les icônes s'estompent quand la fenêtre n'est pas active, teinte d'accent pour la section courante.
- Effet de survol retiré (il ne suivait pas la forme des icônes) ; l'effet natif de barre d'outils reste à reproduire.

## Sidebar

- Verre sombre (`hudWindow`, voile noir 0,45, masque d'arrondi à gauche), plus sombre que la barre et le rail. Flou du fond réglé à 60 (filtre `gaussianBlur` de `CABackdropLayer`, par KVC, réappliqué après 0,5 s car créé après le premier dessin). Trait sombre de 1 pt sur son bord droit.
- Elle glisse par-dessus le panneau (Core Animation, `transform.translation.x`, ease-in-out 0,3 s, réglable par `IPPM_SLIDE_SECONDS`). Les animations sont posées avant la mise en page de l'app (appel `onSidebarChange` différé) pour supprimer le délai avant le départ ; le contenu et la liste s'estompent en fondu.
- Contenu par section : Musique, Podcasts, Livres audio, etc. changent les éléments affichés. La section principale ne peut pas être repliée ; à la place de la flèche, un bouton `plus.circle` n'apparaît qu'au survol du titre (fondu animé) et permet d'ajouter par exemple un dossier à la bibliothèque.
- Redimensionnement par le bord (poignée de 8 pt posée au niveau de la zone, au-dessus des autres vues) : largeur de 128 à 400 pt (bornée pour laisser 760 pt au contenu). Comme dans le Finder : sous 64 pt elle se ferme d'un coup, sans animation, et dans le même geste, en revenant à 80 pt, elle se rouvre d'un coup à 128 pt puis suit le pointeur. Le curseur redevient normal au relâchement.

## Barre d'outils et recherche

- Bouton de bascule de sidebar : `NSToolbarItem` (barre unifiée). Champ de recherche : `NSSearchToolbarItem` (macOS 11+, avec `#available`), dans les identifiants par défaut, masqué ou montré par `isHidden` (macOS 15). ⌘F via l'élément de menu Édition ; `beginSearchInteraction()`.
- Anciens boutons + et ↻ de l'en-tête retirés sur Mac : l'ajout passe par le « + » de la sidebar ; l'actualisation reste à replacer (menu « … » ou barre de menus).
- La marge droite du champ de recherche diffère de celle du panneau : imposée par le système.

## Performance du redimensionnement

Mesuré en build release : une mise en page de l'app après un changement de largeur coûte **~40 ms** (84 ms en debug), soit un plafond d'environ 25 images par seconde. Le profil du fil principal montre le temps dans le graphe de vues de SwiftCrossUI (`ViewGraphNode.computeLayout` / `commit`, `withObservationTracking` imbriqué).

Solution retenue (macOS) : pendant le glisser, la largeur est **native**. Les vues de la sidebar sont redimensionnées directement et le contenu, encore calculé pour l'ancienne largeur, est déplacé par sa couche (aucune mise en page de l'app à chaque mouvement). L'app ne recalcule qu'une fois, au relâchement ou au claquement ouvert/fermé. Tant que sa mise en page n'a pas rattrapé la valeur, tout ce qu'elle valide entre-temps est remis en place aussitôt (observateurs de `frameDidChange`, `liveWidth`). Limite : pendant le glisser, le contenu garde sa largeur d'avant (légère coupe ou marge à droite), corrigée au relâchement.

Première tentative, abandonnée : la même idée sans rattrapage, la sidebar reprenait sa largeur dès que l'app validait autre chose (chargement de la bibliothèque, etc.).

Piste pour la suite et pour GTK/WinUI : conteneurs de séparation natifs (`GtkPaned`, `SplitView`/`Grid` WinUI), SwiftCrossUI ne gardant que le contenu des panneaux. Détail dans [[Manques SwiftCrossUI]].

## Mise à jour de SwiftCrossUI

Le dépôt amont a avancé après la v0.10.0 (pas de nouvelle étiquette ; dernier commit testé : `276025d`, 7 novembre 2026). Il apporte `labelsHidden`, la prise en charge de `NavigationSplitView` compact sur iOS, des tests. Essai de passage à ce commit : **refusé à la compilation**, car le commit exige macOS 12 alors que l'app cible macOS 10.15.4 (« Bump minimum platform requirements to match Xcode 27 OS versions »). Les trois patchs locaux (`gtk-backend`, `representables`, `winui-backend`) s'appliquent sans conflit sur ce commit. Retour à la v0.10.0 exacte. À reconsidérer si l'on relève la cible à macOS 12, ou quand une version étiquetée sortira.

## Ouvert

- Effet de survol et d'appui natif du rail ; fluidité du redimensionnement (voir ci-dessus) ; latence au changement de vue.
- Arrière-plan translucide de la page iPod (encore opaque #282828).
- Portage Windows (WinUI, `IsInputActive = true`) et Linux (GTK) de la même disposition.
- Carte du GitHub Project (jeton `gh` invalide) ; licence de la police SF avant distribution.
- Outils de développement dans `WindowChromeMac.swift` : variables `IPPM_FRONT`, `IPPM_SLIDE_SECONDS` ; à retirer ou documenter avant livraison.
