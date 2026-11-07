# Captures d'écran en développement

Comment regarder l'interface sans la prendre à l'œil, y compris à distance, et ce que les captures ne montrent pas (7 novembre 2026, macOS 15.7.1).

## Outils de l'app (macOS)

| Variable | Effet |
|---|---|
| `IPPM_SNAPSHOT=<fichier.png>` | enregistre la fenêtre telle que l'app la dessine (`cacheDisplay` de la vue racine), puis quitte |
| `IPPM_SNAPSHOT_DELAY=<s>` | attente avant la capture (1,5 s par défaut) |
| `IPPM_SNAPSHOT_COLLAPSED=1` | ferme d'abord la sidebar |
| `IPPM_SELECT_MUSIC=1` | reste sur la page Musique avec l'iPod simulé branché (sinon l'app ouvre la page de l'iPod, qui n'a pas de sidebar) |
| `IPPM_FRONT=1` | fenêtre au premier plan, à (120, 120) |

Mesurer sur une capture : l'image est à 2 px par point. Un petit script Swift (`NSBitmapImageRep.colorAt`) donne les lignes occupées par un élément (centre du titre, de l'icône), à 0,25 pt près ; c'est ainsi que le titre de la sidebar a été centré sur l'icône iPod du rail.

## Ce que `cacheDisplay` ne montre pas

- **Flou et transparence** du verre derrière la fenêtre : la capture ne contient que ce que l'app dessine, pas le fond. Les panneaux semblent opaques ; ce n'est pas le cas à l'écran.
- **Survol** des boutons : il vient d'événements souris réels.
- **Fenêtre inactive** : lancée sans activation, la fenêtre est grisée (boutons rouge, jaune, vert gris).
- **`maskedCorners`** : non respecté au rendu dans une image, ce qui arrondissait les quatre coins de la teinte de la sidebar sur les captures. Le code utilise désormais un masque de forme (`CAShapeLayer`), identique à l'écran et en capture.

## Ce qui est impossible sans autorisation

`screencapture` et `CGWindowListCreateImage` (même de l'app sur sa propre fenêtre) renvoient une image vide ou refusent sans le droit « Enregistrement de l'écran » ; les événements souris synthétiques (`CGEventPost`) n'arrivent pas à la fenêtre sans le droit « Accessibilité ». Donner ces deux droits au terminal permettrait des captures réelles, avec survol.

## Mesurer la hiérarchie de vues

Pour comprendre une disposition, un parcours récursif de `window.contentView?.superview` écrit classe, cadre et rayon d'angle de chaque vue (`NSLog`). C'est ainsi que la barre de titre (38 pt de haut, `NSTitlebarContainerView` › `NSTitlebarView` › `NSToolbarView`) et le coin arrondi de la sidebar ont été trouvés. Code jetable, non conservé.
