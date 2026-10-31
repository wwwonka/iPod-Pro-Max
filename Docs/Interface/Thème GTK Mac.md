# Thème GTK Mac

Une feuille de style `MacTheme.css` embarquée dans l'app. Elle est chargée au démarrage sur Windows et Linux avec `GtkCssProvider`, à la priorité `APPLICATION`, au-dessus du thème du système. Le rendu est donc le même partout, quel que soit le thème de la distro.

## Ce qu'elle redéfinit
- **Fenêtre** : barre de titre unifiée avec la barre d'outils (`GtkHeaderBar`), boutons de fenêtre ronds rouge, jaune et vert à gauche.
- **Sidebar** : fond légèrement translucide ou teinté, sélection en pilule arrondie à l'accent bleu, icônes monochromes.
- **Tables** : lignes aérées, alternance de fond discrète, en-têtes de colonne fins, sélection bleue.
- **Contrôles** : boutons arrondis (rayon de 6 px), champs de recherche en pilule, interrupteurs façon macOS, barres de progression fines.
- **Typographie** : Inter embarquée (proche de SF Pro, licence OFL), tailles alignées sur macOS (13 pt pour le corps).
- **Couleurs** : accent `#007AFF`, modes clair et sombre qui suivent le réglage de l'OS.
- **Icônes** : un jeu d'icônes façon SF Symbols, libre de droits, embarqué. SF Symbols eux-mêmes ne sont pas redistribuables hors des plateformes Apple.

## Références
- Thèmes GTK façon macOS existants (WhiteSur, licence MIT) : on s'en inspire, ou on en reprend des parties en respectant leur licence.

## Validation
Captures d'écran des mêmes écrans sur macOS (AppKit), Windows et Linux (GTK), comparées côte à côte à chaque étape de la phase 5. Voir [[Phases]].

Voir aussi [[Un code, look Mac partout]] et [[Risques]] (fidélité du thème).
