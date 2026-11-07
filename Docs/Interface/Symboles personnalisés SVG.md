# Symboles personnalisés (SVG)

Le 7 novembre 2026. Code dans `UI/CustomSymbols.swift` et `UI/Symbols.swift` ; la source de l'illustration est `iPod Pro Max/Resources/Symbols/<nom>.svg`.

## But

Utiliser une illustration qui n'existe pas dans SF Symbols (Apple Music, `apple-music`, et Podcasts, `podcasts`) exactement comme un SF Symbol : par son nom, avec la teinte, le survol, l'appui et la sélection de n'importe quel autre glyphe du rail.

## Fonctionnement (macOS)

- `CustomSymbol(svgPath:strokeWidth:)` lit un tracé SVG (commandes `M`, `L`, `l`, `C`, `Z`, les seules utilisées par les illustrations) en une liste d'étapes. Le registre `customSymbols` associe un nom à son tracé. Les points de contrôle des courbes participent aux bornes pour empêcher un dessin courbe d'être cadré trop grand.
- `systemSymbol(name, pointSize:)` regarde d'abord ce registre : un nom personnalisé donne une `NSImage` dessinée à la volée dans un `NSBezierPath`, **marquée modèle** (`isTemplate`), centrée dans un carré. Sans `strokeWidth`, le chemin est rempli ; avec une épaisseur, il est tracé avec extrémités et jointures rondes. Le reste du code (`RailButton`, `Symbol`, la sidebar) ne voit aucune différence avec un vrai symbole.
- Taille : hauteur du glyphe = 1,15 × la taille de police demandée (le glyphe est étroit et paraissait petit à 0,92) ; carré de 1,4 × la taille.
- Le tracé est **copié dans le code**, pas lu au lancement (`Package.swift` exclut `Resources`, et l'exécutable portatif ne porte pas de ressources). Si le SVG change, il faut recopier son attribut `d` dans `customSymbols`.

## Utilisation actuelle

- `SidebarItem.music.icon` vaut `apple-music` : icône du bouton Music du rail et de la ligne Music quand elle est affichée ailleurs.
- `SidebarItem.podcasts.icon` vaut `podcasts`. La source est un tracé de contour : 15 pt dans le rail et `strokeWidth` de 1,35 unité SVG, choisis visuellement pour retrouver la taille et le poids du SF Symbol `book` voisin.
- Dans la liste de la sidebar, la ligne « All Songs » prend le vrai symbole `music.quarternote.3` (voulu ainsi : l'icône Apple Music est réservée au rail).

## Windows et Linux

Ils dessinent les symboles avec une police de glyphes, sans équivalent pour ces SVG. `customSymbolFontStandIns` renvoie vers les glyphes les plus proches (`apple-music` → `music.note`, `podcasts` → `antenna.radiowaves.left.and.right` ; `music.quarternote.3` → `music.note`, absent de la police). **Reste à faire** : dessiner les tracés (GTK : zone de dessin Cairo ; WinUI : élément `Path`), non essayé faute de pouvoir compiler et vérifier là-bas depuis le Mac.

## Rail : largeur normalisée

Les glyphes SF diffèrent beaucoup en largeur à 17 pt. Dans `makeButton`, un glyphe SF plus large que `MediaRailMetrics.glyphMaxWidth` (21 pt) est dessiné à une taille réduite pour tenir dans cette largeur. Photos et Games ont un traitement optique distinct : 17,5 pt et une limite de 22 pt, afin de ne pas annuler leur léger agrandissement. Les glyphes personnalisés sont exclus de cette normalisation et reçoivent leur propre taille. Voir [[Rail de médias macOS]].
