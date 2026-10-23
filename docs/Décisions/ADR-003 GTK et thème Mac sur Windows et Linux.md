# ADR-003 GTK et thème Mac sur Windows et Linux

- **Statut** : acceptée, le 2026-10-22
- **Contexte** : SwiftCrossUI propose WinUI ou GTK4 sur Windows. WinUI donne un look Windows et exige le Windows App Runtime sur la machine, ce qui est incompatible avec une app portable sur un PC quelconque.
- **Décision** : **GtkBackend sur Windows et sur Linux**, avec une feuille de style `MacTheme.css` embarquée et appliquée par-dessus le thème du système (voir [[Thème GTK Mac]]). Les DLL GTK4 sont livrées à côté du `.exe`.
- **Conséquences** :
  - même rendu Mac-like sur Windows et Linux, et un seul backend à soigner en plus d'AppKit ;
  - environ 40–60 Mo de DLL de plus dans `App/Windows` ;
  - l'app ne ressemble pas à une app Windows native : c'est voulu, le look Mac est l'objectif (voir [[Vision]]).
