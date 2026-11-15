# Notes d'implémentation — Section Musique (MUS-1 à MUS-32)

Ces notes préparent le terrain pour l'implémentation de [feature-music-section.md](file:///Users/julien/orca/workspaces/iPod-Pro-Max/finish-music-section/Docs/_Specs/feature-music-section.md) sur les trois plateformes (macOS AppKit, Linux GTK4, Windows WinUI 3).

---

## 1. Recently Added

### MUS-1 – Vue Recently Added en vue liste

**OBJECTIF (rappel)**  
Remplacer la grille d'albums actuellement affichée pour `Recently Added` par la vue liste partagée (`TrackTable`), triée par défaut par date d'ajout décroissante et respectant les colonnes globales.

**FICHIERS EXISTANTS**  
- `iPod Pro Max/App/App.swift` (dans `header(_:)`, `trackTableActive(_:)`, `tableRows(_:)` et `cover(_:)` pour `.recentMusic` : passer de `library.recentAlbums` / `AlbumBrowser` à `library.recentRows` / `TrackTable`, et retirer le bouton de retour d'album pour `.recentMusic`)
- `iPod Pro Max/Library/Library.swift` (`library.recentRows` existe déjà et trie par `dateAdded` décroissante avec départage par l'ordre déjà trié artiste/album/disque/piste ; vérifier le message d'état vide et l'exposition de `dateAdded` pour le tri par colonne)
- `iPod Pro Max/UI/TrackTable.swift` (supporter le tri initial par défaut par date d'ajout décroissante lorsqu'on entre dans `.recentMusic`, ainsi que le basculement sur clic d'en-tête sur macOS, GTK et WinUI)

**A CRÉER**  
- Aucun nouveau fichier indispensable (réutilisation directe de `TrackTable` et `library.recentRows`).

**DEPENDANCES**  
- MUS-4 et MUS-5 (les colonnes visibles dans `Recently Added` suivent l'état global des colonnes).
- MUS-2 et MUS-3 (l'icône de favori cliquable dans `TrackTable` s'applique aussi à `Recently Added`).

**RISQUES / PERFORMANCE**  
- `library.recentRows` est déjà calculé hors thread principal lors de l'indexation dans `Library.index(_:source:)`, sans recalcul par rendu.
- Pendant un import en cours, `ContentView` rafraîchit la bibliothèque par lots : `TrackTable` doit préserver la position de défilement (en particulier sous macOS/GTK/WinUI où `setRows` appelle actuellement `reloadData()` / `deselectAll()`).
- Sous WinUI, `TrackTable` utilise actuellement une ligne texte simple au lieu des colonnes virtuelles complètes (commentaire existant dans `TrackTable.swift`) ; le rendu multi-colonnes devra rester aligné.

**QUESTIONS OUVERTES**  
- Un tri choisi manuellement par l'utilisateur dans `Recently Added` doit-il être conservé à la prochaine ouverture ou revenir systématiquement à la date d'ajout décroissante ?
- Quelle fenêtre temporelle ou quel nombre maximal de morceaux définit « récent » (actuellement `library.recentRows` contient toute la bibliothèque triée par `dateAdded` décroissante) ?

---

## 2. Favorites

### MUS-2 – Icône de favori cliquable partout

**OBJECTIF (rappel)**  
Remplacer le préfixe texte `"★  "` actuellement figé dans les cellules par une vraie icône SF Symbol cliquable (`heart` / `heart.fill` par défaut) permettant de basculer l'état favori sans changer la sélection ni lancer la lecture.

**FICHIERS EXISTANTS**  
- `Sources/iPodKit/LibraryModels.swift` (`LibraryTrack.isFavorite` existe déjà en `Bool?`, persisté dans le cache portable et réconcilié via `PortableFavoriteReference` dans `Sources/iPodKit/PortableLibrary.swift`)
- `iPod Pro Max/Library/Library.swift` (`Track.isFavorite` et `TrackRow.isFavorite` existent déjà)
- `iPod Pro Max/App/App.swift` (`setFavorite(_:)` et `enqueueLibraryWrite("favorites")` existent déjà ; attention : ligne 681 efface `selectedSongIDs = []` après écriture, ce qui contredit la règle « sans modifier la sélection » ; également revoir les boutons temporaires `Favorite` / `Remove Favorite` de la barre de titre)
- `iPod Pro Max/UI/TrackTable.swift` (remplacer le `"★  "` textuel dans `CenteredTrackCell` sur macOS, dans `setupCell`/`bindCell` sur GTK et dans `TrackTable` sur WinUI par un contrôle icône cliquable avec état survol, contour vs plein couleur d'accent, et gestion de la sélection multiple ou mixte)
- `iPod Pro Max/UI/ArtistTrackList.swift` (remplacer également `"★  " + song.title` par le même composant/comportement d'icône favori)
- `iPod Pro Max/UI/AlbumBrowser.swift`, `iPod Pro Max/UI/AlbumBrowserGtk.swift`, `iPod Pro Max/UI/AlbumBrowserWinUI.swift` (afficher l'icône de favori dans la vue Albums / détail d'album)
- `iPod Pro Max/UI/Symbols.swift` (ajouter les codepoints SF-Symbols 4 pour `heart`, `heart.fill`, `star`, `star.fill` afin qu'ils s'affichent sous Linux GTK et Windows WinUI, pas seulement `star.fill` en caractère Unicode)

**A CRÉER**  
- Un composant ou helper réutilisable de bouton favori par plateforme (ou logique partagée d'état/icône + gestion de sélection mixte : si au moins un morceau sélectionné n'est pas favori, tout passer à favori).
- Câblage d'un callback `onToggleFavorite` sur `TrackTable`, `ArtistTrackList` et `AlbumBrowser`.

**DEPENDANCES**  
- MUS-3 (le symbole affiché — cœur ou étoile — dépend du réglage global dans Settings).
- MUS-24 (le Metadata Editor affiche aussi l'icône de favori à côté de la note en étoiles).

**RISQUES / PERFORMANCE**  
- Le clic sur l'icône dans une ligne `NSTableView` / `GtkListView` / `WinUI.ListView` ne doit ni déclencher la sélection de ligne ni interférer avec le double-clic de lecture ou le début d'un glisser-déposer.
- Mettre à jour l'état visuel de façon optimiste et regrouper les écritures via `enqueueLibraryWrite` pour ne pas bloquer le thread principal ni déclencher de rechargement complet de la table qui ferait sauter le scroll.
- Sur Linux/Windows sans la police `SF-SYMBOLS4.TTF`, `Symbols.swift` doit prévoir un repli lisible (comme `★` / `☆` ou `♥` / `♡`).

**QUESTIONS OUVERTES**  
- L'état favori (`isFavorite`) doit-il être synchronisé vers l'iPod (par exemple converti en note `rating` dans `SyncEngine.swift` / `ITunesDBModel.swift`) ?
- Quel emplacement exact pour l'icône de favori dans la grille Albums vs dans la liste des morceaux du détail d'album (`AlbumExpansion`) ?

---

### MUS-3 – Réglage cœur / étoile dans Settings

**OBJECTIF (rappel)**  
Ajouter dans les Préférences un réglage permettant de choisir l'icône de favori entre `heart` et `star`, appliqué immédiatement dans toute l'interface et persisté entre les sessions.

**FICHIERS EXISTANTS**  
- `Sources/iPodKit/PortableLibrary.swift` (ajouter le champ de préférence dans `PortableSettings`, avec valeur par défaut cœur)
- `iPod Pro Max/Platforms/PortablePreferences.swift` (ajouter `stageFavoriteIcon` dans `Pending` et `Writer.write` pour persister dans `settings.json`)
- `iPod Pro Max/Library/SettingsController.swift` (exposer l'état courant du symbole favori, lire depuis `settings.json` dans `attach(_:)`, mettre à jour via `PortablePreferences` et notifier via `onChange` / un observateur partagé avec la fenêtre principale)
- `iPod Pro Max/UI/SettingsView.swift` (ajouter le sélecteur visuel cœur vs étoile avec aperçu des icônes dans l'onglet `General` ou `Playback`)
- `iPod Pro Max/App/App.swift` (relayer le changement de réglage à la fenêtre principale sans redémarrage pour rafraîchir `TrackTable`, `AlbumBrowser` et le Metadata Editor)

**A CRÉER**  
- Un type ou énumération partagé décrivant le style d'icône de favori (cœur vs étoile, noms SF Symbol plein et contour) accessible à la fois depuis `SettingsController` et les vues.

**DEPENDANCES**  
- MUS-2 (tous les boutons/icônes favoris consomment ce réglage).
- MUS-24 (l'onglet Details du Metadata Editor utilise aussi ce réglage).

**RISQUES / PERFORMANCE**  
- `SettingsView` tourne dans une `Window` séparée (`id: "settings"`) : la synchronisation avec la fenêtre principale doit passer par un mécanisme événementiel (`SettingsController.shared` ou notification), sans polling ni timer.
- Éviter que le changement de symbole ne force un ré-index complet de la bibliothèque (`Library.portable`), un simple rafraîchissement des cellules/vues visibles suffit.

**QUESTIONS OUVERTES**  
- Dans quel onglet de `SettingsView` (`General` ou `Playback`) placer ce réglage ?
- Avec l'étoile choisie comme icône de favori, comment la distinguer visuellement des cinq étoiles de la note dans le Metadata Editor (écart, séparateur ou couleur distincte) ?

---

## 3. Columns

### MUS-4 – Menu contextuel sur la barre d'en-têtes de colonnes

**OBJECTIF (rappel)**  
Permettre un clic droit n'importe où sur la barre d'en-têtes de `TrackTable` (y compris dans l'espace vide à droite) pour afficher un menu listant toutes les colonnes disponibles avec une coche sur celles visibles.

**FICHIERS EXISTANTS**  
- `iPod Pro Max/UI/TrackTable.swift` :
  - Actuellement, les colonnes sont définies en constante globale `columns` (6 colonnes : `#`, `Title`, `Artist`, `Album`, `Year`, `Time`).
  - Sur macOS : attacher un `NSMenu` au `tableView.headerView` (`NSTableHeaderView`), en gérant le clic droit sur toute sa largeur (y compris après la dernière colonne) et les éléments verrouillés (colonne `Title` grisée et cochée, non cliquable).
  - Sur GTK : `TrackTable` utilise `gtk_column_view_new` — identifier la barre d'en-tête ou attacher un `GtkGestureClick` (bouton secondaire) avec un `GMenu` / `GtkPopoverMenu` sur les titres de colonnes.
  - Sur WinUI : la barre d'en-tête est un `WinUI.Grid` (`header` dans `makeWinUIElement`) — lui attacher un `MenuFlyout` sur clic droit (`RightTapped`).

**A CRÉER**  
- Définition étendue du modèle de colonnes disponibles (incluant la colonne `Date Added` pour MUS-1, et potentiellement d'autres champs existants sur `TrackRow`, ainsi que le caractère verrouillé de `Title` et la distinction colonnes globales vs colonnes propres à une vue comme l'ordre dans une playlist).

**DEPENDANCES**  
- MUS-5 (chaque action du menu met à jour l'état global partagé des colonnes visibles).
- MUS-1 (`Recently Added` a besoin de la colonne `Date Added` ou d'un tri par date d'ajout).
- MUS-20 (une playlist peut avoir une colonne d'ordre propre à la vue playlist).

**RISQUES / PERFORMANCE**  
- Sous macOS, `NSTableHeaderView` ne transmet pas toujours un menu contextuel sur la zone vide à droite des colonnes si `columnAutoresizingStyle = .noColumnAutoresizing` ; il faudra sous-classer `NSTableHeaderView` ou surcharger `menu(for:)` dessus.
- Si l'utilisateur masque la colonne actuellement utilisée pour le tri, le tri doit retomber proprement sur le tri par défaut de la vue sans crash d'index hors limites.

**QUESTIONS OUVERTES**  
- Liste exacte des colonnes proposées dans le menu (uniquement les colonnes actuelles `#`, `Title`, `Artist`, `Album`, `Year`, `Time`, plus `Date Added`, ou d'autres comme `Genre`, `Plays`, `Rating`, `BPM` ?) ?
- Confirmer que la colonne `Title` est bien toujours verrouillée (impossible à masquer).

---

### MUS-5 – État global des colonnes et persistance entre sessions

**OBJECTIF (rappel)**  
Partager l'ensemble des colonnes visibles entre toutes les vues liste (`Songs`, `Recently Added`, `Favorites`, playlists, etc.) et le sauvegarder entre les lancements.

**FICHIERS EXISTANTS**  
- `Sources/iPodKit/PortableLibrary.swift` (ajouter le réglage des colonnes visibles dans `PortableSettings`, par exemple une liste d'identifiants de colonnes masquées ou visibles)
- `iPod Pro Max/Platforms/PortablePreferences.swift` (ajouter le staging et l'écriture de la liste des colonnes dans `settings.json`)
- `iPod Pro Max/UI/TrackTable.swift` (remplacer le tableau statique `columns` par la lecture de l'état global ; masquer/afficher les `NSTableColumn` sur macOS, les `GtkColumnViewColumn` sur GTK, et reconstruire/masquer les colonnes du `Grid` sous WinUI sans perdre la position de défilement)
- `iPod Pro Max/App/App.swift` (charger et appliquer les préférences de colonnes au chargement de la bibliothèque dans `loadPortable` et propager aux instances `TrackTable`)

**A CRÉER**  
- Un contrôleur ou store observable léger (ex. `ColumnVisibilityStore` dans `iPod Pro Max/UI/` ou `iPod Pro Max/Library/`) qui détient l'état courant en mémoire, notifie toutes les vues `TrackTable` actives immédiatement, et déclenche `PortablePreferences.shared` pour la persistance.

**DEPENDANCES**  
- MUS-4 (le menu contextuel lit et modifie cet état global).
- MUS-1 et MUS-20 (les vues `Recently Added` et playlists utilisent cet état global, tout en gardant les colonnes propres à une vue comme l'ordre de playlist hors du réglage global).

**RISQUES / PERFORMANCE**  
- Basculer la visibilité d'une colonne ne doit pas déclencher `table.reloadData()` complet si les données n'ont pas changé (sur macOS, `column.isHidden` suffit sans perdre le scroll).
- Attention à bien isoler les colonnes spécifiques à une vue (ordre dans une playlist) pour qu'elles ne soient ni propagées aux autres vues ni proposées dans le menu des autres vues.

**QUESTIONS OUVERTES**  
- Comment traiter les vues non musicales (`Videos`, `Podcasts`, `Audiobooks`) qui réutilisent aussi `TrackTable` : doivent-elles partager exactement les mêmes colonnes globales ou avoir leur propre réglage ?

---

## 4. Sidebar Reorder

### MUS-6 – Réordonner un élément de la sidebar par glissement

**OBJECTIF (rappel)**  
Permettre de réordonner n'importe quel élément de la sidebar par clic maintenu puis glissement vertical, tout en gardant le clic simple pour la sélection et en annulant avec `Échap` ou un relâchement hors zone.

**FICHIERS EXISTANTS**  
- `iPod Pro Max/UI/SidebarMac.swift` (`MusicDropOutlineView` / `Sidebar.Coordinator` sur macOS : aujourd'hui `NSOutlineView` ne gère le drag que comme cible de dépôt pour des pistes via `TrackDrag` ; ajouter une session de glissement interne pour le réordonnancement ou un tracking souris inspiré de `MediaRailView.reorder(_:)` dans `iPod Pro Max/UI/MusicShell.swift`)
- `iPod Pro Max/UI/SidebarGtk.swift` (ajouter le drag & drop / suivi de pointeur sur les lignes des `GtkListBox` de chaque section)
- `iPod Pro Max/UI/SidebarWinUI.swift` (activer `canReorderItems` / `allowDrop` ou le suivi de pointeur sur les `ListView` de section)

**A CRÉER**  
- Logique de suivi du geste de réordonnancement (seuil de déplacement pour distinguer clic simple et glissement, gestion de la touche `Échap` pour annuler, auto-scroll près des bords haut/bas pour les longues listes).

**DEPENDANCES**  
- MUS-7 (contraintes de groupe d'origine).
- MUS-8 (animation d'écartement des voisins façon Finder).
- MUS-9 (persistance du nouvel ordre).
- MUS-16 à MUS-19 (les nouvelles playlists et dossiers créés se placent à la fin du groupe et peuvent ensuite être déplacés).

**RISQUES / PERFORMANCE**  
- Conflit critique avec le dépôt de morceaux/albums (`TrackDrag`) sur les playlists ou iPods : utiliser un type de pasteboard/drag distinct (ou un tracking local sans `TrackDrag.payload`) pour ne jamais confondre un réordonnancement de sidebar avec un ajout de morceaux.
- Ne pas modifier `selection` lors du glissement d'un élément non sélectionné, ou restaurer la sélection sans recharger la vue de détail.

**QUESTIONS OUVERTES**  
- Aucune spécifique à MUS-6 (voir MUS-7 pour le périmètre des groupes).

---

### MUS-7 – Limiter le déplacement au groupe d'origine

**OBJECTIF (rappel)**  
Empêcher un élément de quitter son groupe d'origine lors d'un glissement (les items de `Music`/bibliothèque restent dans `Music`, les playlists restent dans `Playlists`).

**FICHIERS EXISTANTS**  
- `iPod Pro Max/UI/Sidebar.swift` (`SidebarSection` sépare déjà les groupes `"iPods"`, `"Music"`, `"Playlists"`, et la note de section `"Video Playlists"` pour les vidéos)
- `iPod Pro Max/UI/SidebarMac.swift` (`Node` connaît son parent/groupe ; lors du glissement dans `NSOutlineView`, restreindre les indices cibles valides aux enfants du même `Node` de groupe et bloquer les en-têtes de groupe)
- `iPod Pro Max/UI/SidebarGtk.swift` (chaque section a déjà son propre `GtkListBox`, ce qui facilite le confinement au groupe)
- `iPod Pro Max/UI/SidebarWinUI.swift` (chaque section a déjà son propre `ListView`, ce qui confine naturellement les cibles)

**A CRÉER**  
- Aucun fichier dédié ; logique de validation de cible dans les coordinateurs des trois implémentations de `Sidebar`.

**DEPENDANCES**  
- MUS-6 (geste de glissement).
- MUS-19 (interaction éventuelle entre glisser une playlist sur un dossier de playlists vs simple réordonnancement).

**RISQUES / PERFORMANCE**  
- Sous macOS, noter que le groupe `"iPods"` est filtré hors de `SidebarMac.swift` (`filter { $0.title != "iPods" }`) car les iPods vivent dans `MediaRail` (`iPod Pro Max/UI/MusicShell.swift`) où ils ont déjà leur propre logique de placement, alors que sur GTK/WinUI il faut vérifier si `"iPods"` est dans la sidebar.

**QUESTIONS OUVERTES**  
- Les en-têtes de groupe (`Music`, `Playlists`, `iPods`) sont-ils bien non déplaçables ?
- Si les appareils `iPods` apparaissent dans la sidebar (GTK/WinUI), leur réordonnancement est-il utile ou exclu ?
- Glisser une playlist sur un dossier de playlists (MUS-19) doit-il la ranger dans le dossier ou rester un simple réordonnancement ?

---

### MUS-8 – Animation de déplacement façon Finder

**OBJECTIF (rappel)**  
Animer le réordonnancement de la sidebar comme dans le Finder : élément glissé translucide suivant le pointeur, voisins qui s'écartent en douceur devant une cible valide, aucun écartement hors du groupe, et glissement fluide jusqu'à la position finale au relâchement.

**FICHIERS EXISTANTS**  
- `iPod Pro Max/UI/MusicShell.swift` (référence existante dans `MediaRailView.reorder(_:)` avec `NSAnimationContext`, suivi d'événements et déplacement des voisins)
- `iPod Pro Max/UI/SidebarMac.swift` (animation de `NSOutlineView` via `moveItem` / `beginUpdates` / `endUpdates` ou animation de calques des lignes pendant le drag)
- `iPod Pro Max/UI/SidebarGtk.swift` (animation CSS/transitions ou réordonnancement animé dans `GtkListBox`)
- `iPod Pro Max/UI/SidebarWinUI.swift` (transitions de réordonnancement natives `ListView` / `RepositionThemeTransition`)

**A CRÉER**  
- Un aperçu/calque flottant pour la ligne en cours de glissement si l'animation native de `NSOutlineView` ne rend pas l'élément translucide sous le pointeur.

**DEPENDANCES**  
- MUS-6 et MUS-7.

**RISQUES / PERFORMANCE**  
- Éviter toute reconstruction complète de la sidebar (`reloadData()` / `rebuild()`) pendant le glissement : mettre à jour uniquement les positions visuelles pendant le drag et ne valider l'ordre dans le modèle qu'au relâchement.
- Respecter « zéro travail au repos » : aucune boucle d'animation ou timer actif une fois le dépôt terminé.

**QUESTIONS OUVERTES**  
- Aucune spécifique (calquer la réactivité sur `MediaRailView.reorder` déjà présent dans le projet).

---

### MUS-9 – Persistance de l'ordre de la sidebar

**OBJECTIF (rappel)**  
Sauvegarder l'ordre personnalisé des éléments de chaque groupe de la sidebar et le restaurer au lancement suivant, en plaçant tout nouvel élément à la fin de son groupe.

**FICHIERS EXISTANTS**  
- `Sources/iPodKit/PortableLibrary.swift` :
  - Pour les playlists (et dossiers de playlists), l'ordre du tableau `playlists` dans le cache portable reflète déjà l'ordre ; réordonner `cache.playlists` persiste automatiquement l'ordre des playlists.
  - Pour les éléments fixes du groupe `Music` (`recentMusic`, `artists`, `albums`, `favorites`, `music`), ajouter un champ dans `PortableSettings` (ex. ordre des identifiants `SidebarItem.rawValue`).
- `iPod Pro Max/Platforms/PortablePreferences.swift` (ajouter le staging et la sauvegarde de l'ordre des items de la bibliothèque dans `settings.json`)
- `iPod Pro Max/UI/Sidebar.swift` (`sidebarSections(...)` doit trier les lignes de `Music` selon l'ordre sauvegardé, en ajoutant à la fin tout nouvel item non encore présent dans la liste sauvegardée)
- `iPod Pro Max/App/App.swift` (transmettre l'ordre sauvegardé à `Sidebar` et gérer le callback de réordonnancement : `PortablePreferences` pour les items fixes, `updatePlaylists` pour les playlists)

**A CRÉER**  
- Aucun nouveau fichier ; extension de `PortableSettings` / `PortablePreferences` et callback `onReorder` sur `Sidebar`.

**DEPENDANCES**  
- MUS-6, MUS-7, MUS-8.
- MUS-18 et MUS-19 (les nouvelles playlists et dossiers créés sont ajoutés en fin de liste).

**RISQUES / PERFORMANCE**  
- Si l'application est mise à jour avec de nouvelles sections dans `Music`, la fonction de fusion dans `sidebarSections` doit tolérer les identifiants inconnus (les ignorer) et ajouter les nouveaux items à la fin.

**QUESTIONS OUVERTES**  
- L'ordre des playlists dans `Sidebar` doit-il être identique à l'ordre utilisé lors de la synchronisation sur l'iPod (`cache.playlists`) ? (Réutiliser `cache.playlists` garantit cette cohérence automatiquement.)

---

## 5. Albums View

### MUS-10 – Visuels du glisser d'album

**OBJECTIF (rappel)**  
Soigner l'apparence du glisser d'album depuis la grille : fondu du titre, de l'artiste et du rectangle de sélection sur la tuile, réduction d'échelle et translucidité des pochettes glissées (avec pile + compteur en cas de sélection multiple).

**FICHIERS EXISTANTS**  
- `iPod Pro Max/UI/AlbumBrowser.swift` (`AlbumTile`, `AlbumCollectionView`, et `collectionView(_:pasteboardWriterForItemAt:)` / `draggingSession` sur macOS)
- `iPod Pro Max/UI/AlbumBrowserGtk.swift` (ajouter la source de drag GTK sur les tuiles d'albums + icône de drag personnalisée avec pile/compteur)
- `iPod Pro Max/UI/AlbumBrowserWinUI.swift` (ajouter `canDrag` / `dragStarting` sur les tuiles d'albums WinUI)
- `iPod Pro Max/UI/TrackDrag.swift` (étendre si besoin pour fournir un aperçu visuel ou compter les albums/pistes glissés)

**A CRÉER**  
- Un générateur/cache d'image d'aperçu de drag (ex. empilement de 1 à 3 pochettes réduites + badge compteur au-delà de quelques albums) calculé une seule fois au début du drag.

**DEPENDANCES**  
- MUS-14 (si l'album glissé fait partie d'une sélection multiple, toute la sélection est emportée ; sinon uniquement l'album sous le pointeur).
- MUS-15 (le bouton de lecture au survol doit être masqué pendant un glissement).

**RISQUES / PERFORMANCE**  
- Ne jamais recalculer l'image d'aperçu ni les effets visuels à chaque frame du drag ; réutiliser les vignettes déjà en cache dans `ThumbnailStore` / `GtkThumbnailStore` et limiter la pile d'aperçu à 3–4 pochettes maximum avec un badge numérique pour les grandes sélections.

**QUESTIONS OUVERTES**  
- Aucune bloquante (les timings d'animation peuvent suivre les standards Finder/AppKit).

---

### MUS-11 – Défilement automatique au clic sur un album

**OBJECTIF (rappel)**  
Lorsqu'on clique sur un album pour ouvrir son détail, faire défiler la grille de manière animée afin d'aligner le haut de la pochette cliquée sur le haut de la zone visible (ou au maximum possible pour la dernière rangée), sans défilement si on referme un album déjà ouvert.

**FICHIERS EXISTANTS**  
- `iPod Pro Max/UI/AlbumBrowser.swift` (dans `Coordinator.activate(_:in:)`, après `reflow(collectionView, reload: true)`, calculer le cadre de l'item sélectionné et animer `clipView.animator().setBoundsOrigin(...)` vers le haut de l'item, clampé aux bornes du document)
- `iPod Pro Max/UI/AlbumBrowserGtk.swift` (animer la `GtkAdjustment` verticale du `GtkScrolledWindow` vers la position `y` de la rangée cliquée — attention : ligne 92-99 restaure actuellement l'ancien scroll `preservedScroll`, il faudra distinguer un reload de sélection d'un resize)
- `iPod Pro Max/UI/AlbumBrowserWinUI.swift` (scroller le `ScrollViewer` interne du `ListView` vers la rangée de l'album sélectionné avec animation)

**A CRÉER**  
- Aucun fichier ; méthode de défilement animé dans chaque `AlbumBrowser`.

**DEPENDANCES**  
- MUS-12 et MUS-13 (le panneau de détail `AlbumExpansion` s'ouvre juste sous la rangée alignée).
- MUS-14 (un clic simple alors qu'une sélection multiple existe réduit la sélection à cet album et déclenche l'ouverture + défilement).

**RISQUES / PERFORMANCE**  
- Sous macOS, `collectionView.reloadData()` réinitialise parfois la mise en page avant que les frames ne soient à jour : appeler `layoutSubtreeIfNeeded()` avant de lire le frame de l'item cible pour l'animation de scroll.
- Attention aux boucles de rappel pendant l'animation de scroll : ne pas relancer de `reflow` pendant le défilement.

**QUESTIONS OUVERTES**  
- Aucune.

---

### MUS-12 – Fond de pochette floutée/filigrane dans le détail d'album

**OBJECTIF (rappel)**  
Afficher la pochette de l'album ouvert en grand et floutée (ou atténuée en filigrane) derrière la liste des morceaux de l'album, en garantissant la lisibilité en mode clair comme en mode sombre et en gardant un fond neutre s'il n'y a pas de pochette.

**FICHIERS EXISTANTS**  
- `iPod Pro Max/UI/AlbumBrowser.swift` (`AlbumExpansion` remplace son fond actuel `NSColor.black.withAlphaComponent(0.24)` par une vue d'image floutée + voile adaptatif clair/sombre)
- `iPod Pro Max/UI/AlbumBrowserGtk.swift` (arrière-plan du conteneur de détail d'album dans `albumRowBind`)
- `iPod Pro Max/UI/AlbumBrowserWinUI.swift` (arrière-plan du détail dans `makeDetail(id:)`)

**A CRÉER**  
- Un helper de rendu/cache de fond flouté (ex. downsample + flou gaussien calculé une seule fois hors thread principal par `artworkKey` et mis en cache, plutôt que d'appliquer un filtre CoreImage/CPU à chaque redimensionnement ou scroll).

**DEPENDANCES**  
- MUS-13 (les textes titre, artiste et année s'affichent par-dessus ce fond).
- MUS-11 (le panneau s'ouvre sous la pochette alignée).

**RISQUES / PERFORMANCE**  
- **Point critique** : ne jamais calculer un flou sur l'image pleine résolution ni à chaque frame. Downsampler l'image (ex. ~64–128 px), appliquer le flou hors du thread principal, et mettre le résultat en cache mémoire (ou `NSVisualEffectView` / `CIFilter` mis en cache sur calque).

**QUESTIONS OUVERTES**  
- Aucune.

---

### MUS-13 – En-tête du détail d'album (album, artiste, année)

**OBJECTIF (rappel)**  
Afficher le nom de l'album, l'artiste et l'année dans la vue de détail de l'album ouvert, sans séparateur orphelin lorsque l'année est absente.

**FICHIERS EXISTANTS**  
- `iPod Pro Max/Library/Library.swift` (`AlbumInfo.year` existe déjà ; vérifier comment `albumInfos(_:)` calcule `year` lorsque les morceaux d'un même album ont des années différentes)
- `iPod Pro Max/UI/AlbumBrowser.swift` (`AlbumExpansion` affiche déjà `title` et `artist`, ajouter `year` à côté ou sous l'artiste avec formatage conditionnel)
- `iPod Pro Max/UI/AlbumBrowserGtk.swift` (vérifier et aligner l'affichage de l'année dans le détail GTK)
- `iPod Pro Max/UI/AlbumBrowserWinUI.swift` (vérifier et aligner l'affichage de l'année dans `makeDetail(id:)`)

**A CRÉER**  
- Aucun fichier ; mise à jour de l'en-tête de détail et du calcul d'année dans `Library.swift`.

**DEPENDANCES**  
- MUS-12 (lisibilité sur le fond flouté).

**RISQUES / PERFORMANCE**  
- Calculer l'année de l'album une seule fois dans `Library.albumInfos(_:)` lors de l'indexation, jamais dans `AlbumExpansion.show`.

**QUESTIONS OUVERTES**  
- Si les morceaux d'un même album ont des années différentes, faut-il afficher l'année la plus ancienne (proposition de la spec) ou la plus fréquente/récente ?

---

### MUS-14 – Sélection multiple d'albums (⌘-clic, rectangle, ⌘A)

**OBJECTIF (rappel)**  
Permettre de sélectionner plusieurs albums par `⌘`-clic (sans ouvrir le détail), par tracé d'un rectangle de sélection dans un espace vide de la grille (additif avec `⌘`), et par `⌘A` (Ctrl+A sous Windows/Linux).

**FICHIERS EXISTANTS**  
- `iPod Pro Max/UI/AlbumBrowser.swift` (`AlbumCollectionView` et `Coordinator` : remplacer `selectedID: String?` unique par un ensemble `selectedIDs: Set<String>` distinct de `expandedID: String?` pour l'album ouvert ; gérer `⌘`-clic dans `mouseDown(with:)`, le tracé d'un rectangle de sélection dans l'espace vide, `selectAll(_:)` / `⌘A` dans `AlbumCollectionView`, et l'affichage du contour de sélection sur `AlbumTile`)
- `iPod Pro Max/UI/AlbumBrowserGtk.swift` (remplacer `gtk_no_selection_new` ou gérer la sélection multiple + rectangle de sélection / `Ctrl+A` / `Ctrl+clic`)
- `iPod Pro Max/UI/AlbumBrowserWinUI.swift` (gérer `selectedIDs`, `Ctrl+clic`, `Ctrl+A` et rectangle de sélection)

**A CRÉER**  
- Une vue ou calque léger d'overlay pour dessiner le rectangle de sélection (rubber-band) pendant le drag dans le vide et calculer l'intersection avec les cadres des tuiles visibles/virtuelles.

**DEPENDANCES**  
- MUS-10 (glisser un album sélectionné emporte toute la sélection).
- MUS-11 (un clic simple sans modificateur réduit la sélection à cet album et ouvre son détail).
- MUS-15 (le bouton play au survol est masqué pendant le tracé d'un rectangle de sélection).

**RISQUES / PERFORMANCE**  
- Bien séparer l'état « album dont le détail est ouvert » (`expandedID`) de l'état « albums sélectionnés » (`selectedIDs`).
- `⌘A` doit sélectionner tous les albums de la vue filtrée courante (`c.albums`), pas toute la bibliothèque non filtrée.

**QUESTIONS OUVERTES**  
- Aucune.

---

### MUS-15 – Bouton de lecture au survol d'un album

**OBJECTIF (rappel)**  
Afficher en fondu un bouton de lecture (`play.circle.fill`) au survol d'une pochette d'album ; un clic lance la lecture depuis le premier morceau sans ouvrir le détail ni modifier la sélection.

**FICHIERS EXISTANTS**  
- `iPod Pro Max/UI/AlbumBrowser.swift` (`AlbumTile` : ajouter `NSTrackingArea` pour détecter le survol et afficher le bouton `play.circle.fill` en fondu ; masquer pendant un drag ou un tracé de rectangle ; appeler `onPlay(album.rows.first, album.rows)` au clic sans propager le clic à `AlbumCollectionView`)
- `iPod Pro Max/UI/AlbumBrowserGtk.swift` (ajouter un `GtkEventControllerMotion` + bouton superposé dans un `GtkOverlay` sur chaque tuile)
- `iPod Pro Max/UI/AlbumBrowserWinUI.swift` (ajouter `pointerEntered` / `pointerExited` + bouton dans un `WinUI.Grid` sur chaque tuile)
- `iPod Pro Max/UI/Symbols.swift` (ajouter le codepoint `play.circle.fill` pour GTK/WinUI)

**A CRÉER**  
- Aucun fichier ; composant bouton de lecture intégré aux tuiles d'albums.

**DEPENDANCES**  
- MUS-10 et MUS-14 (doit être masqué durant les gestes de glissement ou de sélection au rectangle, et ne doit pas altérer `selectedIDs`).

**RISQUES / PERFORMANCE**  
- Créer les boutons de survol ou les `NSTrackingArea` de façon réutilisable dans `AlbumTile` (`prepareForReuse` doit annuler les animations et réinitialiser l'état survolé).
- Intercepter `mouseDown` sur le bouton pour éviter que `AlbumCollectionView.mouseDown` ne déclenche un drag ou l'ouverture du détail.

**QUESTIONS OUVERTES**  
- Si l'album survolé est celui en cours de lecture (`PlaybackController`), le bouton doit-il devenir un bouton pause (`pause.circle.fill`) ?

---

## 6. Playlists

### MUS-16 – Bouton + en fondu sur le groupe Playlists

**OBJECTIF (rappel)**  
Afficher un bouton `+` en fondu au survol du titre de groupe `Playlists` dans la sidebar (et le garder visible quand son menu est ouvert), ouvrant un menu avec trois actions.

**FICHIERS EXISTANTS**  
- `iPod Pro Max/UI/SidebarMac.swift` (`SidebarCell` a déjà un `plusButton` pour `node.isMain` ; étendre le support au groupe `"Playlists"` avec `NSTrackingArea` pour l'apparition en fondu au survol et ouverture d'un `NSMenu` au clic ; garder accessible via menu contextuel sur le titre du groupe)
- `iPod Pro Max/UI/SidebarGtk.swift` (ajouter un `GtkMenuButton` ou bouton avec `GtkEventControllerMotion` sur la ligne d'en-tête `"Playlists"`)
- `iPod Pro Max/UI/SidebarWinUI.swift` (ajouter un bouton avec `MenuFlyout` sur le header `"Playlists"`, apparaissant sur `PointerEntered`)
- `iPod Pro Max/App/App.swift` (câbler les trois actions du menu depuis `Sidebar`)

**A CRÉER**  
- Aucun nouveau fichier ; extension des en-têtes de section dans `SidebarMac`, `SidebarGtk` et `SidebarWinUI`.

**DEPENDANCES**  
- MUS-17, MUS-18 et MUS-19 (les trois entrées du menu).

**RISQUES / PERFORMANCE**  
- Accessibilité / clavier : ne pas rendre l'action uniquement dépendante de la souris (ajouter aussi un menu contextuel sur l'en-tête `"Playlists"` et un focus clavier).

**QUESTIONS OUVERTES**  
- L'actuelle ligne placeholder `"New Playlist…"` mentionnée dans `Sidebar.swift` doit-elle être définitivement supprimée au profit du `+` ?

---

### MUS-17 – Entrée de menu « Add New Music local folder »

**OBJECTIF (rappel)**  
Depuis le menu `+` de `Playlists`, ouvrir un sélecteur de dossier, ajouter le dossier choisi aux sources musicales de la bibliothèque et importer son contenu.

**FICHIERS EXISTANTS**  
- `iPod Pro Max/App/App.swift` (`chooseAndAdd(.music, title: ...)` et `addSource(kind: SourceKind.music.rawValue, folder: ...)` existent déjà et appellent `refreshAfterSourceChange` pour rescanner !)
- `iPod Pro Max/Library/PortableLoading.swift` (vérifier la détection de dossier déjà présent ou sous-dossier d'une source existante afin d'informer l'utilisateur plutôt que de dupliquer silencieusement)
- `Sources/MediaKit/FolderImporter.swift` (import parallèle existant des fichiers audio)

**A CRÉER**  
- Un message d'alerte/retour utilisateur clair si le dossier choisi est déjà suivi, est un sous-dossier d'un dossier déjà suivi, ou ne contient aucun fichier audio lisible.

**DEPENDANCES**  
- MUS-16 (le bouton `+` qui héberge cette entrée de menu).

**RISQUES / PERFORMANCE**  
- Le scan et le hachage/extraction de métadonnées doivent rester sur les tâches détachées existantes (`PortableLoading.load` / `FolderImporter`) sans bloquer le thread principal.

**QUESTIONS OUVERTES**  
- Confirmer que cette entrée a bien sa place dans le menu du groupe `Playlists` bien qu'elle ajoute de la musique à la bibliothèque globale.
- Si un dossier ne contient aucun fichier audio lisible, faut-il l'ajouter quand même aux sources ou le refuser avec un message ?

---

### MUS-18 – Entrée de menu « New Playlist »

**OBJECTIF (rappel)**  
Depuis le menu `+` de `Playlists`, créer une nouvelle playlist vide à la fin du groupe `Playlists` avec son nom immédiatement en édition inline dans la sidebar (texte sélectionné, `Entrée` valide, `Échap` garde le nom par défaut).

**FICHIERS EXISTANTS**  
- `iPod Pro Max/App/App.swift` (ajouter la création de `LibraryPlaylist` via `updatePlaylists`, en générant un nom unique `"New Playlist"`, `"New Playlist 2"`, etc., et en déclenchant le mode édition inline dans la sidebar ; noter que `renamePlaylist` utilisait jusque-là une `NSAlert` modale)
- `iPod Pro Max/UI/SidebarMac.swift`, `iPod Pro Max/UI/SidebarGtk.swift`, `iPod Pro Max/UI/SidebarWinUI.swift` (supporter l'édition inline d'une cellule de playlist nouvellement créée avec sélection automatique du texte et gestion de `Entrée` / `Échap` / perte de focus)

**A CRÉER**  
- Un état transitoire `editingPlaylistID: String?` (ou callback dédié) entre `App.swift` et `Sidebar` pour passer automatiquement la nouvelle ligne en édition dès qu'elle apparaît.

**DEPENDANCES**  
- MUS-16 (déclenchée depuis le menu `+`).
- MUS-9 (la nouvelle playlist s'ajoute à la fin du groupe et son ordre est persisté).
- MUS-20 (sélectionner la playlist affiche sa vue liste vide).

**RISQUES / PERFORMANCE**  
- Éviter que `outline.reloadData()` / `rebuild()` pendant l'édition inline ne détruise le champ texte actif : ne déclencher l'édition qu'une fois la ligne insérée et suspendre les rechargements inutiles pendant la saisie.

**QUESTIONS OUVERTES**  
- Aucune.

---

### MUS-19 – Entrée de menu « New Playlist Folder »

**OBJECTIF (rappel)**  
Depuis le menu `+` de `Playlists`, créer un dossier de playlists vide à la fin du groupe `Playlists` avec édition inline immédiate du nom.

**FICHIERS EXISTANTS**  
- `Sources/iPodKit/LibraryModels.swift` (`LibraryPlaylist` n'a aujourd'hui que `id`, `name`, `trackIDs` : il faut modéliser les dossiers de playlists, par exemple un champ optionnel `isFolder` / `parentID` ou une liste hiérarchique rétrocompatible avec les `library.json` existants)
- `iPod Pro Max/Library/Library.swift` (`Playlist` doit exposer la structure dossier/hiérarchie à `Sidebar`)
- `iPod Pro Max/UI/Sidebar.swift`, `iPod Pro Max/UI/SidebarMac.swift`, `iPod Pro Max/UI/SidebarGtk.swift`, `iPod Pro Max/UI/SidebarWinUI.swift` (afficher les dossiers avec icône dossier + chevron dépliable/repliable, et édition inline du nom à la création)
- `iPod Pro Max/App/App.swift` (action de création de dossier et renommage/suppression)

**A CRÉER**  
- Extension rétrocompatible de `LibraryPlaylist` (et/ou nouveau type `PlaylistFolder`) dans `Sources/iPodKit/LibraryModels.swift` avec décodage tolérant l'absence de champs dans les anciennes bibliothèques.

**DEPENDANCES**  
- MUS-16 (menu `+`).
- MUS-7 et MUS-9 (déplacement et persistance des dossiers et de leur contenu).
- MUS-18 (partage le mécanisme d'édition inline à la création et de déduplication des noms).

**RISQUES / PERFORMANCE**  
- Rétrocompatibilité stricte de `library.json` / `PortableLibraryCache` et de la synchronisation iPod (`SyncEngine.swift` / `ITunesDBModel.swift` / `DeviceView.swift`) : les dossiers ne doivent pas être envoyés tels quels comme des playlists vides sur l'iPod s'ils ne sont pas pris en charge.

**QUESTIONS OUVERTES**  
- Les dossiers de playlists peuvent-ils être imbriqués ?
- Comment les dossiers de playlists doivent-ils apparaître (ou être aplatis/ignorés) lors de la synchronisation sur l'iPod ?
- Glisser une playlist sur un dossier de playlists doit-il la ranger dans le dossier (en lien avec MUS-7) ?

---

### MUS-20 – Contenu d'une playlist en vue liste et réordonnancement interne

**OBJECTIF (rappel)**  
Afficher le contenu d'une playlist dans `TrackTable` en suivant les colonnes globales, trié par défaut selon l'ordre de la playlist, avec réordonnancement manuel des morceaux par glisser-déposer interne et message d'état vide quand la playlist est vide.

**FICHIERS EXISTANTS**  
- `iPod Pro Max/App/App.swift` (`tableRows(_:)` utilise déjà `TrackTable` pour `.playlist(let id)` ; ajouter un `EmptyState` dans `cover(_:)` lorsque `library.rowsByPlaylist[id]` est vide, et câbler un callback `onReorderPlaylistTracks` sur `TrackTable`)
- `iPod Pro Max/UI/TrackTable.swift` (ajouter le support d'une colonne d'ordre de playlist propre à la vue — exclue des colonnes globales — et activer le glisser-déposer de réordonnancement interne uniquement quand la liste est triée par l'ordre de la playlist ; désactiver le réordonnancement manuel si un autre tri de colonne est actif)

**A CRÉER**  
- Logique de réordonnancement interne dans `TrackTable` (indicateur de ligne d'insertion entre les rangées sur macOS/GTK/WinUI, distinct du drag vers la sidebar `TrackDrag`).

**DEPENDANCES**  
- MUS-4 et MUS-5 (colonnes globales + règle d'isolation de la colonne d'ordre propre à la playlist).
- MUS-18 (une playlist nouvellement créée s'affiche avec l'état vide invitant à y glisser des morceaux).

**RISQUES / PERFORMANCE**  
- Différencier proprement un drag de réordonnancement interne dans `TrackTable` d'un drag de copie vers un iPod ou une autre playlist dans la sidebar (`TrackDrag`).
- Lors de l'insertion de morceaux dans une playlist ou de leur réordonnancement, préserver la position de scroll.

**QUESTIONS OUVERTES**  
- Le dépôt de morceaux depuis `Songs` ou `Albums` directement sur la vue liste d'une playlist ouverte doit-il aussi être supporté en plus du dépôt sur la ligne de la sidebar ?

---

## 7. Metadata Editor (fenêtre externe)

### MUS-21 – Fenêtre externe du Metadata Editor

**OBJECTIF (rappel)**  
Remplacer la boîte de dialogue modale rudimentaire actuelle (`NSAlert` dans `MusicTrackTable.showTrackInfo()`) par une véritable fenêtre externe indépendante et multiplateforme, laissant la fenêtre principale visible derrière.

**FICHIERS EXISTANTS**  
- `iPod Pro Max/App/App.swift` (déclarer une nouvelle `Window` SwiftCrossUI dédiée au Metadata Editor, sur le modèle de `Window("Settings", id: "settings")`, et câbler son ouverture via `@Environment(\.openWindow)` / `AppCommands`)
- `iPod Pro Max/App/AppCommands.swift` (ajouter les commandes/raccourci `⌘I` / `Track Info` pour ouvrir l'éditeur depuis la barre de menus ou les vues)
- `iPod Pro Max/UI/TrackTable.swift` (`MusicTrackTable.showTrackInfo()` sur macOS, plus menu contextuel GTK/WinUI pour ouvrir la nouvelle fenêtre au lieu de l'`NSAlert`)
- `iPod Pro Max/UI/AppMenuMac.swift` (raccourci `⌘I` / entrée menu si applicable)

**A CRÉER**  
- Un contrôleur partagé (ex. `MetadataEditorController` dans `iPod Pro Max/Library/`) sur le modèle de `SettingsController`, contenant l'état du ou des morceaux édités, la liste d'origine pour la navigation, les brouillons d'édition et la logique de sauvegarde hors thread principal.
- La vue racine du Metadata Editor (ex. `iPod Pro Max/UI/MetadataEditorView.swift`).

**DEPENDANCES**  
- MUS-22 à MUS-32 (tous les composants internes de la fenêtre).

**RISQUES / PERFORMANCE**  
- Comme `SettingsView`, une `Window` SwiftCrossUI séparée ne partage pas l'état `@State` de `ContentView` : toute communication passe par le contrôleur partagé et les callbacks événementiels (zéro polling).
- Gérer le cas où le morceau édité est supprimé de la bibliothèque pendant que la fenêtre est ouverte.

**QUESTIONS OUVERTES**  
- Une seule fenêtre d'éditeur réutilisée à la fois (comme iTunes) ou plusieurs fenêtres possibles en parallèle ?
- L'édition simultanée de plusieurs morceaux sélectionnés (« Mixed ») est-elle incluse dès cette version ?
- Un morceau présent uniquement sur un iPod (hors bibliothèque hôte) est-il éditable ou en lecture seule ?

---

### MUS-22 – En-tête du Metadata Editor (pochette, titre, artiste, album)

**OBJECTIF (rappel)**  
Afficher en haut de la fenêtre un en-tête persistant entre les onglets avec la vignette de pochette à gauche (ou image de remplacement), le titre en grand (tronqué si trop long) et l'artiste/album en dessous, reflétant en direct les saisies.

**FICHIERS EXISTANTS**  
- `iPod Pro Max/UI/Thumbnail.swift` (réutiliser le chargement asynchrone mis en cache pour la vignette de l'en-tête)

**A CRÉER**  
- Vue d'en-tête intégrée à `iPod Pro Max/UI/MetadataEditorView.swift` (ou sous-vue dédiée), liée aux champs brouillons `title`, `artist`, `album` et à la pochette en cours d'édition.

**DEPENDANCES**  
- MUS-21 (fenêtre externe).
- MUS-24 (mises à jour en direct depuis les champs de l'onglet Details).
- MUS-27 (mise à jour immédiate de la vignette lors d'un ajout de pochette dans l'onglet Artwork).
- MUS-32 (style translucide de cet en-tête).

**RISQUES / PERFORMANCE**  
- Utiliser le cache de vignettes (`ThumbnailStore` / `GtkThumbnailStore`) pour la miniature de l'en-tête et éviter tout décodage d'image haute résolution sur le thread principal.

**QUESTIONS OUVERTES**  
- Aucune.

---

### MUS-23 – Organisation en six onglets (Details, Artwork, Lyrics, Options, Sorting, File)

**OBJECTIF (rappel)**  
Structurer le corps du Metadata Editor autour d'une barre de six onglets (`Details`, `Artwork`, `Lyrics`, `Options`, `Sorting`, `File`) avec mise en évidence de l'onglet actif par la couleur d'accent, tout en conservant l'en-tête et la barre du bas fixes.

**FICHIERS EXISTANTS**  
- `iPod Pro Max/UI/SettingsView.swift` (réutiliser le même pattern de barre d'onglets `AppAccent.color` / survol et de disposition verticale)

**A CRÉER**  
- Énumération des 6 onglets et barre d'onglets dans `iPod Pro Max/UI/MetadataEditorView.swift`.

**DEPENDANCES**  
- MUS-24, MUS-27, MUS-28, MUS-29, MUS-30, MUS-31 (contenu de chacun des six onglets).
- MUS-25 et MUS-26 (l'onglet actif est conservé lors du passage au morceau précédent/suivant ; `OK` et `Cancel` portent sur tous les onglets).

**RISQUES / PERFORMANCE**  
- Conserver les modifications non enregistrées de tous les onglets dans le brouillon du contrôleur lors du changement d'onglet.

**QUESTIONS OUVERTES**  
- Aucune.

---

### MUS-24 – Onglet Details

**OBJECTIF (rappel)**  
Construire le formulaire `Details` calqué sur iTunes 12 : `song`, `artist`, `album`, `album artist`, `composer` (+ case « Show composer in all views »), `grouping`, `genre` (avec suggestions), `year`, `track` (numéro/total), `disc number` (numéro/total), `compilation`, `rating` (5 étoiles + icône favori), `bpm`, `play count` (lecture seule + date + bouton `Reset`), et `comments`.

**FICHIERS EXISTANTS**  
- `Sources/iPodKit/LibraryModels.swift` (`LibraryTrack` possède déjà `title`, `artist`, `album`, `albumArtist`, `composer`, `grouping`, `genre`, `year`, `trackNumber`, `trackCount`, `discNumber`, `discCount`, `compilation`, `rating`, `isFavorite`, `bpm`, `playCount`, `lastPlayed`, `comment` ; ajouter un champ pour « Show composer in all views » si persisté)
- `Sources/MediaKit/Metadata.swift` (`ID3Genres.names` fournit déjà la liste de genres pour l'autocomplétion/suggestions)
- `Sources/MediaKit/MetadataExtractor.swift`, `Sources/MediaKit/Apple/AVTagReader.swift`, `Sources/MediaKit/Portable/PortableTagReader.swift` (lecture actuelle des tags — **il n'existe aujourd'hui aucun écrivain de tags dans `MediaKit`** hormis `LyricsTagFixup.swift` pour le downgrade ID3v2.4→2.3 et `AudiobookMuxer.swift` via ffmpeg)

**A CRÉER**  
- Service transverse d'écriture de tags audio hors thread principal dans `Sources/MediaKit/` (support MP3/ID3v2, M4A/MP4 atoms, FLAC/Vorbis, WAV/AIFF — via écriture pure Swift ou `FFmpeg`, en évitant toute perte de qualité ou ré-encodage audio).
- Vue de l'onglet `Details` avec validation numérique (`year`, `track`, `disc number`, `bpm`), contrôle 5 étoiles interactif, et bouton `Reset` différé jusqu'à `OK`.

**DEPENDANCES**  
- MUS-2 et MUS-3 (icône favori à côté des étoiles de note).
- MUS-22 (en-tête reflète `song`, `artist`, `album` en direct).
- MUS-30 (les champs de nom sont partagés avec `Sorting`).

**RISQUES / PERFORMANCE**  
- **Risque majeur** : l'écriture de tags dans les fichiers audio n'existe pas encore dans `MediaKit`. Elle doit impérativement s'exécuter hors du thread principal, gérer les fichiers en lecture seule ou absents, et ne pas toucher au flux audio (remplacement atomique des métadonnées / tags uniquement).

**QUESTIONS OUVERTES**  
- Quel est le rôle exact du sélecteur présent à côté du libellé « song » dans la maquette iTunes 12 ?
- Avec l'étoile comme icône de favori (MUS-3), comment distinguer visuellement l'icône de favori des 5 étoiles de notation ?

---

### MUS-25 – Boutons Précédent / Suivant

**OBJECTIF (rappel)**  
Ajouter les flèches précédent/suivant en bas à gauche de la fenêtre pour naviguer dans la liste d'origine sans fermer le Metadata Editor ni changer d'onglet, en désactivant la flèche aux extrémités.

**FICHIERS EXISTANTS**  
- `iPod Pro Max/UI/TrackTable.swift` (lors de l'ouverture du Metadata Editor, passer la liste ordonnée courante `rows` et l'index cliqué au contrôleur de l'éditeur)

**A CRÉER**  
- Logique de curseur et navigation dans `MetadataEditorController` + boutons flèches dans la barre du bas de `MetadataEditorView`.

**DEPENDANCES**  
- MUS-21, MUS-23, MUS-26.

**RISQUES / PERFORMANCE**  
- Lors du passage au morceau suivant/précédent, recharger les métadonnées/détails techniques (`File`, `Lyrics`, `Artwork`) de manière asynchrone hors thread principal pour ne pas geler la fenêtre.

**QUESTIONS OUVERTES**  
- En cas de modifications non enregistrées, passer au morceau suivant doit-il enregistrer automatiquement (comme iTunes) ou demander confirmation ?

---

### MUS-26 – Boutons Cancel et OK

**OBJECTIF (rappel)**  
Ajouter les boutons `Cancel` (`Échap`) et `OK` (`Entrée`) en bas à droite, portant sur l'ensemble des onglets, avec écriture des tags hors thread principal et désactivation de `OK` pendant l'enregistrement.

**FICHIERS EXISTANTS**  
- `iPod Pro Max/App/App.swift` (mettre à jour `PortableLibraryCache` via `enqueueLibraryWrite` après écriture réussie sur disque et ré-indexer `Library`)

**A CRÉER**  
- Pipeline de sauvegarde transactionnelle dans `MetadataEditorController` : écriture des tags dans le(s) fichier(s) hors thread principal -> si échec, garder la fenêtre ouverte, conserver les saisies et afficher l'erreur -> si succès, mettre à jour le cache portable et fermer la fenêtre.

**DEPENDANCES**  
- Tous les onglets éditables (MUS-24, MUS-27, MUS-28, MUS-29, MUS-30).

**RISQUES / PERFORMANCE**  
- Si l'écriture disque échoue (fichier introuvable, permissions, format non supporté), ne pas mettre à jour le cache ni fermer la fenêtre.
- Désactiver `OK` pendant la sauvegarde pour éviter les doubles écritures.

**QUESTIONS OUVERTES**  
- La fermeture de la fenêtre via le bouton rouge/croix de la barre de titre doit-elle être traitée comme `Cancel` ?

---

### MUS-27 – Onglet Artwork

**OBJECTIF (rappel)**  
Construire l'onglet `Artwork` affichant la pochette en grand sous le titre « Album Artwork », avec un bouton `Add Artwork` dans la barre du bas ouvrant un sélecteur d'image et mettant à jour l'en-tête en direct.

**FICHIERS EXISTANTS**  
- `Sources/MediaKit/FolderImporter.swift` / `iPod Pro Max/Platforms/PortableRoot.swift` (stockage des pochettes dans `store.artwork/<artworkKey>.jpg` et calcul du `artworkKey`)

**A CRÉER**  
- Vue de l'onglet `Artwork` dans le Metadata Editor, avec sélecteur de fichier image (`@Environment(\.chooseFile)`), prévisualisation redimensionnée hors thread principal, et écriture dans le tag du fichier + mise à jour du cache `Artwork/`.

**DEPENDANCES**  
- MUS-22 (vignette de l'en-tête mise à jour immédiatement).
- MUS-26 (`OK` valide l'écriture de la pochette).

**RISQUES / PERFORMANCE**  
- Ne pas charger/décoder une image très lourde (ex. 4000x4000 px) sur le thread principal ; redimensionner/compresser en tâche de fond et valider les formats d'image pris en charge.

**QUESTIONS OUVERTES**  
- Une pochette ajoutée s'applique-t-elle uniquement au morceau édité ou à tous les morceaux du même album ?
- Faut-il supporter le glisser-déposer d'une image sur la zone pochette, ainsi que la suppression/remplacement d'une pochette existante ?

---

### MUS-28 – Onglet Lyrics

**OBJECTIF (rappel)**  
Construire l'onglet `Lyrics` avec une grande zone de texte défilante et la case `Custom Lyrics` dans la barre du bas qui active l'édition et enregistre les paroles avec le morceau.

**FICHIERS EXISTANTS**  
- `Sources/iPodKit/LibraryModels.swift` (`LibraryTrack.hasLyrics` existe déjà ; le texte complet des paroles n'est pas stocké dans `library.json`, il doit être lu à la demande depuis le fichier audio)
- `Sources/iPodKit/LyricsTagFixup.swift` (rappel important : les iPods classiques ne lisent que les paroles USLT en ID3v2.3 pour les MP3)
- `Sources/MediaKit/Portable/PortableTagReader.swift` / `Sources/MediaKit/Apple/AVTagReader.swift` (actuellement seul `hasLyrics: Bool` est remonté dans `ExtractedMetadata`, il faudra lire le texte complet des paroles à l'ouverture de l'onglet)

**A CRÉER**  
- Méthode de lecture du texte des paroles dans `MediaKit` (à la demande pour le morceau ouvert) + écriture des paroles (`USLT` / `©lyr` / `LYRICS`) dans le futur écrivain de tags.
- Vue de l'onglet `Lyrics` avec zone de texte multi-lignes défilante et case `Custom Lyrics` dans la barre du bas.

**DEPENDANCES**  
- MUS-26 (`OK` enregistre les paroles et met à jour `hasLyrics` sur `LibraryTrack` / `TrackRow`).

**RISQUES / PERFORMANCE**  
- Lire les paroles à la demande hors thread principal uniquement quand l'éditeur ouvre un morceau, ne pas charger toutes les paroles de toute la bibliothèque en RAM.

**QUESTIONS OUVERTES**  
- Décocher `Custom Lyrics` alors que du texte est déjà saisi doit-il effacer les paroles du fichier à la validation ou simplement les masquer/conserver ?
- Quel lien futur avec une éventuelle recherche de paroles par plug-in ?

---

### MUS-29 – Onglet Options

**OBJECTIF (rappel)**  
Construire l'onglet `Options` : `media kind` (menu), `start` et `stop` (case à cocher + temps), `Remember playback position` et `Skip when shuffling` (cases à cocher), `volume adjust` (curseur −100 % à +100 %), et `equalizer` (menu).

**FICHIERS EXISTANTS**  
- `Sources/iPodKit/LibraryModels.swift` (`LibraryTrack` a déjà `kind: MediaKind?`, mais pas encore `startTimeMs`, `stopTimeMs`, `rememberPlaybackPosition`, `skipWhenShuffling`, `volumeAdjust`, `eqPreset`)
- `Sources/iPodKit/ITunesDBModel.swift` et `Sources/iPodKit/ITunesDBWriter.swift` (`IPodTrack` possède déjà `volume`, `startTime`, `stopTime`, `skipWhenShuffling`, `rememberPlaybackPosition`, et le format iTunesDB supporte l'EQ !)
- `Sources/iPodKit/SyncEngine.swift` (propager ces options de `LibraryTrack` vers `IPodTrack` lors de la synchronisation)
- `iPod Pro Max/Library/PlaybackController.swift` (vérifier si la lecture locale dans l'app respecte `start`/`stop`/`volumeAdjust`)

**A CRÉER**  
- Ajout des champs d'options de lecture sur `LibraryTrack` (rétrocompatible `Codable`).
- Vue de l'onglet `Options` avec validation de plage (`stop` >= `start` et <= durée du morceau).

**DEPENDANCES**  
- MUS-26 (`OK` valide ; si `media kind` change pour autre chose que `Music`, le morceau quitte la section Musique après ré-indexation).

**RISQUES / PERFORMANCE**  
- Rétrocompatibilité des fichiers `library.json` / caches portables existants (utiliser des types optionnels ou des valeurs par défaut au décodage).

**QUESTIONS OUVERTES**  
- Quels réglages exactement l'iPod respecte-t-il réellement (`start`/`stop`, `volume`, `equalizer`, `skip when shuffling`, `remember playback position`) ? Ceux non pris en charge doivent-ils être masqués ?

---

### MUS-30 – Onglet Sorting

**OBJECTIF (rappel)**  
Construire l'onglet `Sorting` avec cinq paires de champs (`name`, `album`, `album artist`, `artist`, `composer`) et leur champ `sort as` associé affichant la valeur du champ de nom en grisé lorsqu'il est vide.

**FICHIERS EXISTANTS**  
- `Sources/iPodKit/LibraryModels.swift` (ajouter `sortTitle`, `sortAlbum`, `sortAlbumArtist`, `sortArtist`, `sortComposer` sur `LibraryTrack`)
- `Sources/iPodKit/ITunesDBModel.swift` et `Sources/iPodKit/ITunesDBWriter.swift` (`IPodTrack` et les `MHODType` `sortTitle`, `sortArtist`, `sortAlbum`, `sortAlbumArtist`, `sortComposer` existent déjà et sont déjà utilisés par `LibraryIndexSort` !)
- `Sources/iPodKit/SyncEngine.swift` (transmettre les champs `sort*` de `LibraryTrack` vers `IPodTrack`)
- `Sources/MediaKit/Portable/PortableTagReader.swift` et `Sources/MediaKit/Apple/AVTagReader.swift` (lire les frames/atoms de tri existants `TSOT`, `TSOP`, `TSOA`, `TSO2`, `TSOC` / `sonm`, `soar`, `soal`, `soaa`, `soco`)

**A CRÉER**  
- Vue de l'onglet `Sorting` liée de façon bidirectionnelle avec les champs de nom de `Details` (MUS-24) et avec placeholder grisé dynamique.

**DEPENDANCES**  
- MUS-24 (partage des champs `name`, `album`, `album artist`, `artist`, `composer`).
- MUS-26 (`OK` écrit dans les tags et le cache).

**RISQUES / PERFORMANCE**  
- S'assurer que l'indexation locale (`Library.swift`) et la synchro iPod (`SyncEngine.swift`) utilisent bien les champs `sort*` s'ils sont renseignés.

**QUESTIONS OUVERTES**  
- Aucune.

---

### MUS-31 – Onglet File (lecture seule)

**OBJECTIF (rappel)**  
Construire l'onglet `File` affichant les informations techniques en lecture seule (`kind`, `duration`, `size`, `bit rate`, `sample rate`, `channels`, `volume`, `id3 tag`, `encoded with`, `format`, `date modified`, `date added`, `location`), en masquant les champs non applicables au format.

**FICHIERS EXISTANTS**  
- `Sources/iPodKit/LibraryModels.swift` (`LibraryTrack` a déjà `durationMs`, `bitrate`, `sampleRate`, `fileSize`, `fileExtension`, `dateAdded`, `dateModified`, `path`)
- `Sources/MediaKit/Portable/PortableTagReader.swift` (lit déjà les en-têtes MP3/ID3/M4A/FLAC : étendre une inspection technique à la demande pour remonter `channels`, `id3 tag` version, `encoded with`, `format` détaillé, `volume`/SoundCheck)

**A CRÉER**  
- Struct d'informations techniques détaillées lue de manière asynchrone à l'ouverture de l'onglet `File` (pour ne pas alourdir `LibraryTrack` ni la RAM pour toute la bibliothèque).
- Vue de l'onglet `File` en texte simple sélectionnable/copiable sans cadre de champ.

**DEPENDANCES**  
- MUS-25 (changement de morceau met à jour l'inspection technique).

**RISQUES / PERFORMANCE**  
- Ne jamais stocker toutes ces chaînes techniques par piste dans `library.json` ni les lire à l'import : les inspecter uniquement à l'ouverture du Metadata Editor sur le fichier concerné, hors thread principal.

**QUESTIONS OUVERTES**  
- Faut-il ajouter un bouton ou lien cliquable sur `location` pour révéler le fichier dans le Finder / l'explorateur ?

---

### MUS-32 – En-tête translucide du Metadata Editor

**OBJECTIF (rappel)**  
Rendre le bandeau d'en-tête du Metadata Editor translucide avec flou d'arrière-plan natif sur macOS, Windows et Linux (et repli opaque de même teinte si la transparence est réduite ou indisponible), tout en gardant le corps de la fenêtre opaque.

**FICHIERS EXISTANTS**  
- `iPod Pro Max/UI/SettingsWindowMac.swift` (référence directe sur macOS : `NSVisualEffectView` avec `.underWindowBackground`, `.behindWindow`, `titlebarAppearsTransparent = true`, `.fullSizeContentView`)
- `iPod Pro Max/UI/WindowChromeWinUI.swift` (référence Windows : backdrop acrylic / mica sur la zone haute, corps opaque dessous)
- `iPod Pro Max/UI/WindowChromeGtk.swift` / `iPod Pro Max/UI/GlassGtk.swift` (référence Linux GTK : gestion de transparence / flou et détection de réduction de transparence)

**A CRÉER**  
- Un modificateur ou probe de fenêtre dédié au Metadata Editor (ex. `MetadataWindowChrome` sur le modèle de `SettingsWindowChrome`), appliquant le matériau translucide uniquement sur la hauteur de l'en-tête et un fond opaque sur la zone onglets + contenu + barre du bas.

**DEPENDANCES**  
- MUS-21 (fenêtre externe) et MUS-22 (en-tête).

**RISQUES / PERFORMANCE**  
- Sous macOS, `NSVisualEffectView` limité au bandeau d'en-tête fonctionne matériellement sans coût CPU par frame ; sous Linux/Windows, prévoir le repli opaque propre si le compositeur ou l'accessibilité désactive la transparence.

**QUESTIONS OUVERTES**  
- Aucune.
