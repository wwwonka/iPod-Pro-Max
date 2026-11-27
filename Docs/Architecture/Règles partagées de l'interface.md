# Règles partagées de l'interface

Depuis le 2026-11-27, les décisions de l'interface ne sont plus prises dans les fichiers `*Mac.swift`. Elles sont dans du code partagé, sans framework d'interface, et testées. Chaque backend (AppKit aujourd'hui, GTK et WinUI au portage) traduit seulement ses événements en entrées et dessine le résultat. Le portage n'aura donc pas à réécrire ces règles trois fois (voir [[Modules]], [[ADR-006 Noyau portable sans dépendance Apple]]).

| Module | Fichier | Ce qu'il décide | Côté Mac | Tests |
|---|---|---|---|---|
| `LibrarySession` + `PlaylistEdits` | `iPod Pro Max/Library/LibrarySession.swift`, `Sources/iPodKit/PlaylistEdits.swift` | Toutes les modifications de la bibliothèque : déplacer, réordonner, renommer, ajouter ou retirer des pistes de playlists, favoris. Les écritures sont regroupées, et seules les playlists sont réindexées (1 à 2 ms au lieu d'environ 100 ms sur 5 355 pistes). | `ContentView` (`App.swift`) n'est plus qu'un relais | `PlaylistEditsTests` |
| `SidebarRules` | `Sources/iPodKit/SidebarRules.swift` | Les lignes qu'on peut glisser, le point d'insertion, ce que fait un dépôt (vers un iPod, dans un dossier, réordonnancement) et le menu contextuel d'une playlist | `SidebarMac.swift` | `SidebarRulesTests` |
| `PlayerLCDPresentation` | `Sources/MediaKit/PlayerLCDPresentation.swift` | Ce que le LCD affiche : priorité activité, puis erreur, puis piste, puis repos ; éléments visibles selon le mode ; textes, temps, paroles, vitesse ; indicateurs d'activité ; estompage en pause ; clé de fondu | `PlayerLCDContentMac.swift` (animations, pochettes, tracé) | `PlayerLCDPresentationTests` |
| `PlayerHeaderRules` | `Sources/iPodKit/PlayerHeaderRules.swift` | La page qui possède la recherche, et ce qui s'affiche selon la largeur (champ, loupe ou rien ; repli sous 900 pt) ; l'action, le symbole et le libellé du bouton Play (pause, lancer la sélection, ou Stop avec ⌥) ; le niveau du haut-parleur ; l'ouverture unique de la fenêtre au lancement | `WindowChromeMac.swift`, `ToolbarPlayerMac.swift` | `PlayerHeaderRulesTests` |

## Règles à suivre
- **Toute nouvelle décision d'interface** (visibilité, texte, action, ordre) va dans l'un de ces modules, ou dans un nouveau module du même genre, jamais dans un fichier `*Mac.swift`.
- **Ces modules sont appelés à chaque événement** : mouvement du pointeur, avancée de la lecture, rafraîchissement. Ils restent en O(1) ou O(lignes), sans allocation inutile et sans accès disque.
- **Les tests passent par l'interface du module**, sans fenêtre : `swift test --filter "PlaylistEdits|SidebarRules|PlayerLCDPresentation|PlayerHeaderRules"`.

## Reste à faire
- `PlaybackController` dépend encore de callbacks remplis au lancement par d'autres fichiers. Il devrait lancer lui-même la lecture, aller dans MediaKit et être testé avec un faux moteur audio.
