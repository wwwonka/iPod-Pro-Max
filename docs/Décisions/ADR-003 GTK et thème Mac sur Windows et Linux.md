# ADR-003 GTK et thème Mac sur Windows et Linux

- **Statut** : acceptée le 2026-10-22, **à revoir** depuis le prototype P1 (2026-10-25)
- **Contexte** : SwiftCrossUI propose WinUI ou GTK4 sur Windows. WinUI donne un look Windows et exige le Windows App Runtime sur la machine, ce qui est incompatible avec une app portable sur un PC quelconque.
- **Décision** : **GtkBackend sur Windows et sur Linux**, avec une feuille de style `MacTheme.css` embarquée et appliquée par-dessus le thème du système (voir [[Thème GTK Mac]]). Les DLL GTK4 sont livrées à côté du `.exe`.
- **Conséquences** :
  - même rendu Mac-like sur Windows et Linux, et un seul backend à soigner en plus d'AppKit ;
  - environ 40–60 Mo de DLL de plus dans `App/Windows` ;
  - l'app ne ressemble pas à une app Windows native : c'est voulu, le look Mac est l'objectif (voir [[Vision]]).

## Ce que le prototype P1 a montré (2026-10-25)
- Le prototype tourne avec le backend **par défaut** de chaque OS : **WinUI 3 sur Windows**, GTK 4 sur Linux. WinUI s'est installé et lancé sans difficulté majeure dans la VM (Windows App Runtime installé par le script de build).
- L'utilisateur veut maintenant être **« natifs le plus possible »** : Mica sous Windows, widgets natifs par plateforme ([[Composants natifs par plateforme]]), tout en gardant un look Mac (sidebar, icônes, boutons de fenêtre façon Mac, peut-être avec une option pour les boutons natifs).
- GTK sous Windows n'a pas été essayé.
- **À trancher** : WinUI (natif, Mica, mais Windows App Runtime à livrer ou installer pour le mode portatif) ou GTK sous Windows (portable, un backend de moins, pas de Mica). Voir [[Lancement portatif par OS]].
