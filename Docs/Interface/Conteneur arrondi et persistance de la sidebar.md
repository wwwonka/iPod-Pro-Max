# Conteneur arrondi et persistance de la sidebar (macOS)

Date : 2026-11-07. Voir aussi [[Séparateur de sidebar natif macOS]], [[Refonte verre macOS]] et [[Rail de médias macOS]].

## Un seul masque pour sidebar et vue principale
- **Problème** : chaque vue décidait de ses propres coins (sidebar arrondie à gauche, vue principale arrondie à droite, puis à gauche si la sidebar était fermée). Pendant l'ouverture ou la fermeture, des coins apparaissaient ou disparaissaient en route.
- **Solution** : `ContainerMask` (`WindowChromeMac.swift`) pose un seul `CAShapeLayer` en masque sur le split view natif. Le masque est un rectangle arrondi (sous les 44 pt de la barre de titre, à l'intérieur des marges de 3 pt, rayon `floatingPanelRadius`) plus la bande de la barre de titre entière. Les pages à l'intérieur sont carrées : les coins ne dépendent plus de l'état de la sidebar.
- Le masque suit la taille du split (`frameDidChangeNotification`, sans animation implicite).
- Le flou de verre reste visible avec ce masque (vérifié sur capture), contrairement à ce que laissait craindre `SidebarGlassView`, qui découpe encore par `maskImage`.
- Le mode `IPPM_LEGACY_SPLIT` garde ses anciens arrondis.

## Séparateur
- Le séparateur du `NSSplitView` est transparent (`dividerColor`), il ne traverse plus la barre de titre.
- Son bord ne se saisit plus dans les 44 pt du haut (`dividerTopInset`), ni sur la page iPod, où la sidebar n'existe pas (`dividerDragEnabled`). Le curseur de redimensionnement suit la même zone (`addCursorRect`).
- Ces réglages ne sont réappliqués que s'ils changent : les invalider à chaque passe de mise à jour ralentissait l'agrandissement de la fenêtre. Le masque de la sidebar n'est aussi recalculé que si la taille change, sans animation implicite.
- Patch : `Tools/Build/Patches/appkit-backend.patch` (`NSCustomSplitView`).

## Persistance
`settings.json` (dossier Persistent Data) contient maintenant `sidebarWidth` (points, bornée à 180–400) et `lastTab` (`music`, `artists`, `albums`, `playlist:<id>`, etc.).
- La largeur est enregistrée à la fin d'un drag du bord (`NSCustomSplitView.onDragEnd`) et restaurée au chargement des réglages (`MacChrome.setUpSidebarPersistence`).
- Le dernier onglet est enregistré à chaque changement et à la fermeture ou l'éjection ; une playlist supprimée retombe sur Music. Une page iPod n'est pas mémorisée.
- `PortablePreferences` fusionne les changements en attente (mode, largeur, onglet) et les écrit après 500 ms, ou à la fermeture.
- Pas encore fait sur Windows et Linux.

## Autres retouches du jour
- Les pastilles de noms du rail et le menu des extras sont décalés de 1 px vers la droite (`floatingPanelOffset` = 2) ; les pastilles s'effacent en fondu (0,18 s) quand le curseur quitte le rail.
