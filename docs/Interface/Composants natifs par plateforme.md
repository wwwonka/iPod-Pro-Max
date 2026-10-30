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
| Sidebar (`Sidebar`) | `NSOutlineView` *source list* dans un `NSVisualEffectView` (matériau `.sidebar`) ; sections repliables natives | une `GtkListBox` par section, repliée dans un `GtkRevealer`, mise en forme CSS aux mesures du Mac ; fond translucide quand le compositeur floute (Blur my Shell, Hyprland), sinon teinté par le fond d'écran sous GNOME, opaque ailleurs (voir [[Sidebar translucide sous Linux]]) | une `ListView` par section, repliée image par image, sélection dessinée façon Mac ; fond acrylique de la fenêtre (`DesktopAcrylicController`) |
| Icônes (`Symbol`) | `NSImageView` + SF Symbol | `GtkLabel` + police SF Symbols locale | `TextBlock` + police SF Symbols locale |
| Feux et bouton de sidebar (`WindowControls`) | natifs (fenêtre et barre d'outils) | boutons GTK : symboles au survol, gris fenêtre inactive, surbrillance arrondie en CSS | éléments WinUI : symboles au survol, gris fenêtre inactive, `Button` sans bordure pour la surbrillance |
| Fenêtre (`windowChrome`) | barre d'outils unifiée, `NSSplitView` glissé image par image | barre CSD masquée, boutons dessinés, `GtkPaned` glissé sur l'horloge d'affichage | barre de titre repliée, zone de titre et contrôles déclarés à Windows (`InputNonClientPointerSource`), `SplitView` glissé sur `CompositionTarget.Rendering` |

## Règles
- Les données arrivent en `Binding` (voir [[Manques SwiftCrossUI]]) ; la vue native ne recharge que si elles ont changé.
- Les tableaux sont virtualisés : seules les lignes visibles existent.
- Les animations tournent sur l'horloge d'affichage du système et ne relancent pas la mise en page de SwiftCrossUI à chaque image.
- Chaque changement se vérifie sur les trois OS, avec la mesure `IPPM_BENCH` et une capture (`IPPM_SNAPSHOT` sur Mac, `prlctl capture` pour les VM).

Retour à [[Un code, look Mac partout]].
