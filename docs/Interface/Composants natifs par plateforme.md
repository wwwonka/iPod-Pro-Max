# Composants natifs par plateforme

Leçon principale du prototype P1 ([[Prototypes phase 0]]) : SwiftCrossUI convient pour la structure et les petits contrôles, mais **tout ce qui est gros ou sollicité souvent doit être un widget natif**, écrit une fois par plateforme derrière une même vue Swift.

## Pourquoi
- SwiftCrossUI remet toute la fenêtre en page à chaque changement d'état : plus il y a de vues SwiftCrossUI, plus chaque clic coûte.
- Ses composants lourds (`Table`, `List`) créent un widget par cellule ; deux backends sur trois n'ont même pas de `Table`.
- Le natif donne aussi le comportement attendu sur chaque OS (sélection, clavier, accessibilité, défilement).

## Comment
Une seule vue Swift (par exemple `TrackTable`), avec trois implémentations choisies à la compilation :

```swift
#if canImport(AppKitBackend)      // NSViewRepresentable
#elseif canImport(GtkBackend)     // GtkWidgetRepresentable, API C de GTK
#elseif canImport(WinUIBackend)   // WinUIElementRepresentable
#endif
```

| Vue | macOS | Linux | Windows |
|---|---|---|---|
| Tableau des pistes (`TrackTable`) | `NSTableView` | `GtkColumnView` | `ListView` (une ligne de texte par piste pour l'instant) |
| Sidebar (`Sidebar`) | `NSOutlineView` en style *source list* | `GtkListBox` `.navigation-sidebar` | dessinée en SwiftCrossUI (à remplacer) |
| Icônes (`Symbol`) | `NSImageView` + SF Symbol | `GtkLabel` + police SF Symbols locale | à faire |
| Fenêtre (`windowChrome`) | barre d'outils unifiée, `NSSplitView` animé | barre CSD masquée, boutons dessinés, `GtkPaned` animé | à faire |

## Règles
- Les données arrivent en `Binding` (voir [[Manques SwiftCrossUI]]) ; la vue native ne recharge que si elles ont changé.
- Les tableaux sont virtualisés : seules les lignes visibles existent.
- Les animations tournent sur l'horloge d'affichage du système et ne relancent pas la mise en page de SwiftCrossUI à chaque image.
- Chaque changement se vérifie sur les trois OS, avec la mesure `IPPM_BENCH` et une capture (`IPPM_SNAPSHOT` sur Mac, `prlctl capture` pour les VM).

Retour à [[Un code, look Mac partout]].
