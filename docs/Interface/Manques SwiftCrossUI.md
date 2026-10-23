# Manques SwiftCrossUI

Constat sur la **v0.10.0** (30 septembre 2026), dépôt cloné et code lu le 2026-10-22.

| Besoin d'iPod Pro Max | État dans SwiftCrossUI | Où on en a besoin |
|---|---|---|
| `Table` à sélection multiple | `Table(rows, columns)` **sans sélection** | Vue Musique en tableau, onglet iPod |
| Tri par colonne | **Absent** | Vue Musique, Vidéos |
| `List` à sélection multiple | Sélection **simple** seulement | Liste des artistes (multi-artistes) |
| Glisser-déposer | **Absent** du cœur | Glisser des pistes vers l'iPod ou une playlist, réordonner la sidebar, déposer des fichiers à importer |
| Menus contextuels de ligne | À vérifier | Choisir la photo d'un artiste, supprimer, etc. |
| Sélecteur de fichiers et dossiers | À vérifier par backend | Choisir le dossier de musique |
| `@Observable` | **Pris en charge** | Tout AppModel |
| `NavigationSplitView`, `Menu`, sheets, `ProgressView`, `Image` | **Présents** | Structure générale |

## Stratégie
1. **On contribue en amont**, pour AppKit et GTK seulement : `Table` avec `selection: Binding<Set<ID>>` et `sortOrder`, `List` multisélection, `onDrag` / `onDrop`. En AppKit, ça correspond à `NSTableView` et au pasteboard. En GTK4, à `GtkColumnView` + `GtkMultiSelection` et `GtkDragSource` / `GtkDropTarget`.
2. **Si une contribution bloque**, on implémente le widget dans notre propre code, en Swift natif sur chaque backend, derrière la même API.
3. On vérifie ces manques dès le prototype de la phase 0 : c'est le plus gros risque de l'interface. Voir [[Prototypes phase 0]].

Voir [[Un code, look Mac partout]] et [[Risques]].
