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

## Découverts pendant le prototype P1 (2026-10-23 → 25)

| Problème | Effet | Contournement dans le prototype |
|---|---|---|
| `Table` : un widget par cellule, tout remesuré à chaque mise à jour | 7–21 s pour réafficher 5 000 pistes sur Mac | Tableau natif par plateforme ([[Composants natifs par plateforme]]) |
| **`GtkBackend` et `WinUIBackend` n'ont pas de `Table`** | crash au lancement (`does not implement BackendFeatures.Tables`) | idem |
| `.pickerStyle(.segmented)` : AppKit et UIKit seulement | crash sous GTK | sélecteur dessiné hors Mac |
| GTK : `Pango(for:)` crée un contexte par mesure de texte | CSS recalculé à chaque mesure, clics lents | patch local `scripts/patch-dependencies.sh` (à proposer en amont) |
| GTK : aucune détection du mode sombre (`// TODO: React to theme changes`) | toujours clair | lecture de `org.gnome.desktop.interface color-scheme` + signal de changement |
| Une vue native (`NSViewRepresentable`, etc.) reçoit à ses mises à jour les valeurs de sa création | les playlists chargées après n'apparaissaient pas | passer les données en `Binding` |
| `NavigationSplitView` : largeur minimale imposée, pas de repli animé | sidebar impossible à fermer | sidebars natives qui acceptent toute largeur, délégué intermédiaire (Mac), glissement image par image ([[Composants natifs par plateforme]]) |
| **Les vues natives (`NSViewRepresentable`, `GtkWidgetRepresentable`, `WinUIElementRepresentable`) reçoivent pour toujours les valeurs de leur création** | tableau GTK vide après un changement de section ; la recherche ne filtrerait jamais | patch local `scripts/patches/representables.patch` (à proposer en amont) |
| La projection Swift de WinUI n'a pas `DesktopAcrylicBackdrop`, ni `SetRegionRects` (paramètre tableau) | pas d'acrylique, pas de zone de titre | sous-classe de `SystemBackdrop` sur `DesktopAcrylicController` ; appel par la table C de l'interface |
| SwiftCrossUI cherche les métadonnées de Swift Bundler octet par octet au lancement | ~8 % du lancement sous Linux, identifiant GTK `com.example.SwiftCrossUIApp` | `static var metadata` déclarée par l'app |
| GTK : le rendu GL cale les premiers glissements dans la VM (GPU virtio) | 2 images au lieu de 15 | `GSK_RENDERER=vulkan` pour la VM seulement |
| Pas de police nommée, pas d'API de barre de titre | ni SF Symbols ni fenêtre sans barre | widgets natifs et `inspectWindow` |
| Retirer une grosse vue native de la fenêtre recalcule l'ordre du clavier | ~60 ms par clic sur Mac | garder la vue en place |
| Windows : `FileHandle.standardError` plante sans console | crash au lancement depuis l'Explorateur | `fputs` et un fichier journal |
| WinUI : le `SplitView` remet le panneau à la largeur minimale de la sidebar à chaque mise en page, et son déclencheur de mise en page est interne | sidebar impossible à dimensionner ou à faire glisser | patch local `scripts/patches/winui-backend.patch` (à proposer en amont) |
| WinUI : chaque mesure de texte passe par XAML (une douzaine d'appels et une passe de mise en page) | mise en page lente à chaque image d'un redimensionnement | cache des mesures dans le même patch |
| Windows : une tâche Swift sur le thread principal reprend ~100 ms en retard | `await` trop lent pour l'interactif ; mesures faussées | rien d'interactif derrière un `await` ; mesure dans le dispatcher XAML |
| WinUI : les événements d'un `window.content` temporaire ne tiennent leur objet qu'en référence faible | l'abonnement ne fait rien, sans erreur | garder une référence forte sur la racine |

## Stratégie
1. **On contribue en amont**, pour AppKit et GTK seulement : `Table` avec `selection: Binding<Set<ID>>` et `sortOrder`, `List` multisélection, `onDrag` / `onDrop`. En AppKit, ça correspond à `NSTableView` et au pasteboard. En GTK4, à `GtkColumnView` + `GtkMultiSelection` et `GtkDragSource` / `GtkDropTarget`.
2. **Si une contribution bloque**, on implémente le widget dans notre propre code, en Swift natif sur chaque backend, derrière la même API.
3. On vérifie ces manques dès le prototype de la phase 0 : c'est le plus gros risque de l'interface. Voir [[Prototypes phase 0]].

Voir [[Un code, look Mac partout]] et [[Risques]].
