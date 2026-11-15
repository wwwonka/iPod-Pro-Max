# Section Musique et interactions natives macOS

Notes d'architecture et de comportement pour la section Musique complète, la sidebar macOS et l'éditeur de métadonnées.

## Modèle et persistance portable
- `LibraryTrack` (`Sources/iPodKit/LibraryModels.swift`) stocke les champs étendus de métadonnées (paroles, champs de tri, temps de début/fin, mémorisation de position, exclusion de la lecture aléatoire, réglage de volume, préréglage EQ).
- `LibraryPlaylist` supporte les dossiers (`isFolder`, `parentID`) et l'ordre personnalisé de la sidebar est persisté dans `settings.json` (`sidebarOrder`).
- `ListAppearance` (`iPod Pro Max/Library/ListAppearance.swift`) centralise de façon événementielle l'icône de favori (`heart` / `star`) et les colonnes visibles des tableaux sans re-rendre l'arbre SwiftCrossUI ni réindexer la bibliothèque.

## Vues Musique et éditeur de métadonnées
- `TrackTable`, `AlbumBrowser`, `ArtistTrackList`, `ArtistDetail`, `MusicShell` et `Sidebar` complètent la navigation Albums, Artistes, Morceaux, Favoris, Récents et Playlists (avec dossiers imbriqués).
- `MetadataEditorMac` (`iPod Pro Max/UI/MetadataEditorMac.swift`) fournit la fenêtre native d'édition des métadonnées et pochettes sur macOS.
- `SettingsView` ajoute l'onglet `Library` et le choix d'icône de favori dans `General`.

## Sidebar macOS (`SidebarMac.swift`)
- **Glisser-déposer et réordonnancement** : l'annulation (`Escape`) ou le dépôt hors cible valide coupe immédiatement sans animation ; pendant le glisser d'un élément sélectionné, la sélection visuelle est temporairement masquée dans `NSOutlineView` sans changer la section active.
- **Force Click** : configuré via `NSPressureConfiguration(pressureBehavior: .primaryDeepDrag)` ; l'appui profond met la ligne cible en surbrillance tout en supprimant le flash de sélection précédente, bloque le drag, et bascule de section au relâchement (`leftMouseUp`).
- **Renommage en ligne façon Finder** : boîte flottante (`renameBox` à coins arrondis `5 pt` semi-transparents) contenant `innerBox` à coins carrés, bordure intérieure de `1 px` physique semi-translucide (`PassthroughView` au-dessus du `NSScrollView`), `RenameTextView` avec `UndoManager` local (évite le crash AppKit après fermeture) et dessin de sélection bord-à-bord via `layoutManager.enumerateEnclosingRects` sans double alpha.
