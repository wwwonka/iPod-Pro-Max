# Symboles personnalisés (SVG)

Le 7 novembre 2026. Code dans `UI/CustomSymbols.swift` et `UI/Symbols.swift` ; la source de l'illustration est `iPod Pro Max/Resources/Symbols/<nom>.svg`.

## But

Utiliser une illustration qui n'existe pas dans SF Symbols (ici l'icône Apple Music, `apple-music`) exactement comme un SF Symbol : par son nom, avec la teinte, le survol, l'appui et la sélection de n'importe quel autre glyphe du rail.

## Fonctionnement (macOS)

- `CustomSymbol(svgPath:)` lit un tracé SVG (commandes `M`, `L`, `l`, `C`, `Z`, les seules utilisées par l'illustration) en une liste d'étapes. Le registre `customSymbols` associe un nom à son tracé.
- `systemSymbol(name, pointSize:)` regarde d'abord ce registre : un nom personnalisé donne une `NSImage` dessinée à la volée dans un `NSBezierPath`, **marquée modèle** (`isTemplate`), centrée dans un carré. Le reste du code (`RailButton`, `Symbol`, la sidebar) ne voit aucune différence avec un vrai symbole.
- Taille : hauteur du glyphe = 1,15 × la taille de police demandée (le glyphe est étroit et paraissait petit à 0,92) ; carré de 1,4 × la taille.
- Le tracé est **copié dans le code**, pas lu au lancement (`Package.swift` exclut `Resources`, et l'exécutable portatif ne porte pas de ressources). Si le SVG change, il faut recopier son attribut `d` dans `customSymbols`.

## Utilisation actuelle

- `SidebarItem.music.icon` vaut `apple-music` : icône du bouton Music du rail et de la ligne Music quand elle est affichée ailleurs.
- Dans la liste de la sidebar, la ligne « All Songs » prend le vrai symbole `music.quarternote.3` (voulu ainsi : l'icône Apple Music est réservée au rail).

## Windows et Linux

Ils dessinent les symboles avec une police de glyphes, sans équivalent pour ce SVG. `customSymbolFontStandIns` renvoie vers le glyphe le plus proche (`apple-music` → `music.note` ; `music.quarternote.3` → `music.note`, absent de la police). **Reste à faire** : dessiner le tracé (GTK : zone de dessin Cairo ; WinUI : élément `Path`), non essayé faute de pouvoir compiler et vérifier là-bas depuis le Mac.

## Rail : largeur normalisée

Les glyphes SF diffèrent beaucoup en largeur à 17 pt : podcasts 21, livres 23, vidéos 24, photos 26, jeux 28, iPod 16 (en points). Dans `makeButton`, tout glyphe plus large que `MediaRailMetrics.glyphMaxWidth` (21 pt) est dessiné à une taille de police réduite pour tenir dans 21 pt. Les glyphes personnalisés sont exclus du calcul. Voir [[Rail de médias macOS]].
