# Séparateur de sidebar natif macOS

Depuis le 7 novembre 2026, la sidebar de macOS est le `NSSplitView` de SwiftCrossUI (`NavigationSplitView`), comme sur Linux et Windows, et non plus une vue posée par-dessus le contenu. Le glisser du séparateur, l'ouverture et la fermeture par le bouton de la barre d'outils, le changement de page et le zoom de la fenêtre (double clic sur la barre de titre) suivent le pointeur sans saut. Remplace la solution « largeur native + contenu déplacé » décrite dans [[Refonte verre macOS]]. `IPPM_LEGACY_SPLIT=1` ramène l'ancien chemin.

## Où est le code

Le code vit dans `Tools/Build/Patches/appkit-backend.patch` (appliqué par `Tools/Build/patch-dependencies.sh` sur `swift-cross-ui`, comme les autres patchs ; il ne touche pas `NSViewRepresentable.swift`, qui appartient à `representables.patch`). Côté app : `ContentView` dans `App.swift` et `MacChrome` dans `WindowChromeMac.swift`.

| Fichier du patch | Rôle |
|---|---|
| `NSCustomSplitView` | `mouseDown` encadre le suivi du séparateur par `beginDrag` / `endDrag` ; `setSidebarOpen` (animé, 0,3 s, une requête vers la même cible est ignorée) et `setSidebarOpenAtOnce` (instantané, sans layout demandé) |
| `NSSplitViewResizingDelegate` | un layout SwiftCrossUI synchrone à chaque changement de largeur, puis `fillPanes` ; curseurs figés pendant le geste |
| `NSCustomWindow` | zoom : `windowWillResize` hors glisser manuel mémorise la cible, `windowDidResize` suit chaque image |
| `SplitViews`, `WindowReference`, `SplitView` | panneau gauche sans verre ; traces `IPPM_BENCH_LAYOUT` |

## Ce qui a fait osciller le contenu, dans l'ordre où on l'a trouvé

1. **Deux écrivains** : AppKit déplaçait les panneaux et le layout de SwiftCrossUI, un pas en retard, réécrivait les vues du contenu. Les masques d'autoresizing n'agissent pas sur les vues de SwiftCrossUI (Auto Layout) : `fillPanes` / `carry` reportent à la main la largeur gagnée ou perdue aux vues aussi larges que leur parent ou collées à son bord droit.
2. **Double comptage** : une vue de défilement, un tableau ou un champ de texte se redimensionnent seuls ; leur reporter l'écart en plus les rendait 4 à 12 pt trop larges. On ne descend plus dans ces contrôles ni dans une vue déjà à la bonne largeur.
3. **Auto Layout en retard** : le conteneur de la sidebar rattrapait la largeur du panneau au passage suivant. Un observateur de boucle d'exécution (`beforeWaiting`) remet les largeurs en place juste avant l'affichage ; il n'existe que pendant le geste.
4. **Throttle de 8 ms** : un layout sur trois seulement se faisait, donc sidebar et contenu passaient par des largeurs différentes. Essayer « aucun layout pendant le glisser » a été rejeté (le contenu ne suit plus). Solution : un layout synchrone à chaque changement de largeur, sans limite de cadence ; les événements de souris se regroupent seuls pendant qu'il tourne.
5. **Arrondi des colonnes de la table des morceaux** (`TrackScrollView.tile`) : trois colonnes flexibles arrondies chacune vers le bas laissaient jusqu'à 3 pt de reste, qui décalaient Year et Time. La dernière colonne flexible prend le reste exact.

## Page iPod et zoom

- La sidebar n'existe pas sur la page iPod : `MacChrome.setSidebarAvailable` est appelé en tête de `body`, avant le layout, puis `setSidebarOpenAtOnce` ; elle apparaît ou disparaît dans la même image que la page.
- Le contenu a `frame(minWidth: 760, maxWidth: .infinity)` : cela borne la largeur maximale de la sidebar (SwiftCrossUI la limite à total − largeur minimale du contenu) et évite que SwiftCrossUI centre un contenu plus étroit.
- Zoom : AppKit appelle `windowWillResize` avant `windowShouldZoom`, donc on distingue le zoom du glisser manuel par `inLiveResize`.

## Mesures (page vide, glisser simulé de 120 événements)

Mesure faite par `IPPM_BENCH_SIDEBAR=1 IPPM_BENCH_LAYOUT=1`, juste avant l'affichage de chaque image : 0 image sur 560 avec une couche (conteneur, défilement, liste, ligne) hors de la largeur du panneau, côté sidebar comme côté contenu. 28 layouts, médiane 7,0 ms, p90 9,0 ms, max 12,1 ms (budget 16,7 ms à 60 Hz). Non mesuré : Songs avec la vraie bibliothèque de 5 299 pistes.

## Glisser jusqu’à fermer — validation du 18 novembre 2026

`SidebarSplitDelegateProxy` (`WindowChromeMac.swift`) se place devant le délégué de SwiftCrossUI : le séparateur s’arrête à 128 pt et AppKit replie le panneau sous 64 pt. Le comportement natif permet de rouvrir le panneau en ramenant le pointeur vers la droite avant de relâcher.

Le patch AppKit transmet désormais systématiquement la fin du suivi du séparateur, avec une largeur de zéro si le panneau reste replié. Le proxy termine alors la fermeture et restaure la largeur mémorisée avant le geste pour la prochaine ouverture. Ce callback remplace le moniteur local de mouseUp, qui ne reçoit pas nécessairement les événements consommés par la boucle interne d’AppKit.

L’état du chrome doit être mis à jour avant de relayer le redimensionnement à SwiftCrossUI, sinon son layout peut rouvrir le panneau. Le proxy relaie aussi `shouldAdjustSizeOfSubview` et respecte les ouvertures/fermetures programmatiques du backend.

`IPPM_CHECK_SIDEBAR=1` vérifie le seuil, le retour vers la droite dans le même geste, une fermeture achevée, une seule notification de fermeture et la réouverture à la largeur précédente. Ce contrôle et la suite globale `IPPM_CHECK_INTERACTIONS=1` passent dans la vraie application.

## Icônes immobiles pendant le glissement

Mesuré image par image pendant deux fermetures, deux ouvertures et aux largeurs 128 à 250 pt : l'origine des icônes ne bougeait pas, mais leur largeur tombait de 22 à 3 pt dès que la cellule passait sous 36 pt environ. Toutes les contraintes de la cellule étaient requises ; Auto Layout cassait celle de la largeur de l'icône, et le glyphe, centré dans ce cadre, glissait vers la gauche. Les contraintes qui attachent un titre au bord droit de la ligne sont maintenant à la priorité 999 (`makeCell`, `SidebarMac.swift`) : c'est le titre qui cède. Après correction, 51 relevés : icône à x = 62, largeur 22, titre à x = 88, sans exception.

## Limites et suite

- Pendant le glisser, un élément à largeur fixe, ni aussi large que son parent ni collé à son bord droit (un bouton centré), ne se replace qu'au layout suivant.
- Les traces `IPPM_BENCH_LAYOUT` restent dans le patch ; elles ne coûtent rien hors de cette variable.
- À porter : `GtkPaned` (le séparateur est la source de vérité, largeur publiée à la fin) et `SplitView` WinUI (retirer `sidebarResizeHandler` à chaque mouvement). Voir [[Manques SwiftCrossUI]].
- Prochaine étape : l'aspect (verre de la sidebar, retiré pour l'instant).
