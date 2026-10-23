# ADR-002 SwiftCrossUI comme code d'interface unique

- **Statut** : acceptée, à confirmer par le prototype P1 ([[Prototypes phase 0]])
- **Contexte** : on veut une seule base de code qui se compile pour macOS, Windows et Linux, en restant en Swift, avec un look Mac partout.
- **Options étudiées** :
  1. SwiftUI sur Mac + SwiftCrossUI ailleurs : deux codes d'interface.
  2. SwiftUI sur Mac + WinUI 3 direct (swift-winrt) + adwaita-swift : intégration native maximale, mais trois codes et un look Windows ou GNOME.
  3. **SwiftCrossUI partout** (AppKit sur Mac, GTK4 ailleurs) : un seul code.
  4. Flutter ou Electron : look Mac fidèle, mais on quitte Swift.
- **Décision** : option 3. Détail dans [[Un code, look Mac partout]].
- **Conséquences** :
  - il faut contribuer à SwiftCrossUI (voir [[Manques SwiftCrossUI]]) ;
  - l'app SwiftUI actuelle reste livrée jusqu'à la parité ;
  - la logique d'interface doit vivre dans AppModel (voir [[Modules]]).
- **On revient sur cette décision si** : le prototype P1 montre un défilement non fluide sur 5 000 lignes sous GTK, ou des manques impossibles à combler en environ 2 semaines.
