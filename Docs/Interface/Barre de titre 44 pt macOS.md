# Barre de titre à 44 pt (macOS)

Passage de la zone de titre de 52 à 44 pt, le 7 novembre 2026 (MacBook Pro M1 Max, macOS 15.7.1). Code dans `UI/WindowChrome.swift` (`titleBarHeight`) et `UI/WindowChromeMac.swift` (`keepTrafficLightsCentered`). Cadre général : [[Refonte verre macOS]].

## Le problème

La hauteur de la barre d'outils unifiée est décidée par le système, pas par l'app : 52 pt en style `.unified`, 38 pt en `.unifiedCompact`. Aucun style ne donne 44 pt. La constante `titleBarHeight` ne sert qu'à la mise en page de l'app (début du panneau, du rail, de la sidebar) ; la vraie barre doit être amenée à la même hauteur.

## Ce qui est fait

1. `titleBarHeight = 44` et `toolbarStyle = .unifiedCompact`.
2. Le conteneur de la barre de titre (`NSTitlebarContainerView`) est agrandi à 44 pt, collé en haut de la fenêtre, ainsi que la vue `NSToolbarView` qu'il contient (sinon elle reste à 38 pt et ses éléments se centrent à 19 pt). Les cadres sont remis en place à chaque changement (`frameDidChange` du conteneur et des boutons, redimensionnement, plein écran, fenêtre qui devient principale) car AppKit les recalcule.
3. Les boutons rouge, jaune et vert sont recentrés à 22 pt du haut (leur cadre est déplacé dans leur vue parente, avec conversion de coordonnées).
4. Les contrôles de la barre d'outils gardent la taille qu'ils avaient dans la barre de 52 pt : `controlSize = .large` sur les `NSToolbarButton` et les boutons de l'élément de recherche, et sur le champ de recherche. Réappliqué dès qu'un élément apparaît ou disparaît (`scheduleTitleAreaRelayout`).

## Mesures

Hauteurs en points, du haut de la fenêtre.

| Élément | `.unified` (52) | `.unifiedCompact` (38) | Notre barre (44) |
|---|---|---|---|
| Bouton de bascule de la sidebar | 46 × 40 (glyphe 24 × 19) | 30 × 25 | 45,5 × 40, de 2 à 42 |
| Champ de recherche | 31 de haut | 25 | 31, de 7 à 38 (centre 22,5) |
| Boutons rouge, jaune, vert | centrés sur 26 | centrés sur 19 | centrés sur 22 |

Le bouton de bascule fait 40 pt dans 44 : 2 pt de marge de chaque côté, serré. À réduire si l'œil le demande.

## Pistes écartées

- `toolbar.sizeMode = .regular` : sans effet en style compact (le bouton reste à 30 × 25). Le réglage reste dans le code, inoffensif.
- Garder `.unified` : la barre reste à 52 pt.
- Vue personnalisée pour chaque élément de la barre : le fond du bouton (`NSButtonBezelView`) ne suit pas une hauteur forcée ; plus fragile que `controlSize`.

## Limites

- Repose sur les noms de classes privées `NSToolbarView` et `NSToolbarButton` (recherche par `String(describing: type(of:))`). Si le système change la hiérarchie, le recentrage ne fait simplement rien ; les mesures sont à refaire à chaque version majeure de macOS.
- macOS 26 (« Tahoe ») n'a pas été essayé : ses éléments ont un fond en verre et d'autres tailles.
- Le survol des boutons de la barre n'a pas pu être capturé (voir [[Captures d'écran en développement]]).
- Windows et Linux lisent la même constante (44) pour leur mise en page, sans vérification visuelle encore.
