# Un code, look Mac partout

Décisions : [[ADR-002 SwiftCrossUI comme code d'interface unique]] et [[ADR-003 GTK et thème Mac sur Windows et Linux]].

## Le principe
On écrit les vues **une seule fois** avec [SwiftCrossUI](https://github.com/moreSwift/swift-cross-ui). Son API est quasi identique à SwiftUI : `View`, `@State`, `@Observable`, `NavigationSplitView`, `List`, `Table`, `Menu`, sheets. Le backend change selon l'OS :

| OS | Backend | Rendu |
|---|---|---|
| macOS | `AppKitBackend` | Vrais contrôles AppKit : Mac natif |
| Windows | `GtkBackend` (GTK4) + [[Thème GTK Mac]] | Mac-like |
| Linux | `GtkBackend` (GTK4) + [[Thème GTK Mac]] | Mac-like, identique à Windows |

## Pourquoi c'est la meilleure option en Swift
- **Une seule base de code** qui se compile partout. Voir [[Compilation multiplateforme]].
- **Look Mac partout.** WinUI donnerait un look Windows, libadwaita un look GNOME. GTK4 est le seul toolkit natif entièrement thémable en CSS qui tourne sur les trois OS.
- **Seulement deux backends** (AppKit et GTK) à soigner et à compléter. Voir [[Manques SwiftCrossUI]].
- **Pas de Windows App Runtime à installer** sur l'ordi hôte, ce qui est indispensable pour une app portable.

## Alternatives écartées
- **SwiftUI sur Mac + autre chose ailleurs** : deux codes d'interface à maintenir.
- **WinUI 3 direct (swift-winrt, la pile d'Arc) + adwaita-swift** : la meilleure intégration native par OS, mais trois codes d'interface et un look Windows ou GNOME, pas Mac.
- **Flutter (macos_ui) ou Electron** : un look Mac plus fidèle au pixel près, mais il faut quitter Swift et réécrire les 11 000 lignes.

## Ce qu'on accepte
- Sur Mac, certains raffinements SwiftUI (animations, materials, `Table` avancée) sont à refaire dans AppKitBackend ou à simplifier.
- Sur Windows et Linux, le rendu est Mac-like, pas parfait au pixel près.

## Transition sans régression
L'app SwiftUI actuelle reste l'app Mac livrée jusqu'à ce qu'AppUI atteigne la parité, vérifiée écran par écran. Ensuite, elle est retirée. Voir [[Phases]].

## Vues minces
Toute la logique (regroupement par artiste, tri, sélection multiple, cache dérivé indexé par `tracksRevision`, progression) vit dans AppModel. Voir [[Modules]]. Une vue AppUI ne fait que décrire la mise en page.
