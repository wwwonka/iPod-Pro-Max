# Prototypes phase 0

Une semaine pour lever les trois inconnues avant de s'engager. Chaque prototype est jetable et vit hors de l'app, dans `prototypes/` (P1 : `prototypes/swiftcrossui/`, voir son README).

## P1 : vue Musique SwiftCrossUI, look Mac
- Un petit package SwiftCrossUI qui charge un vrai `library.json` (5 000 pistes) et affiche sidebar, liste d'artistes, détail d'album et tableau des pistes.
- On le lance sur AppKit (Mac), GTK Linux (VM) et GTK Windows (VM), avec un premier jet de `MacTheme.css`.
- **On mesure** : défilement fluide sur 5 000 lignes, temps d'ouverture, mémoire.
- **On vérifie** : la difficulté réelle d'ajouter la multisélection et le glisser-déposer à `Table` (voir [[Manques SwiftCrossUI]]).
- **Critère d'arrêt** : si le défilement de 5 000 lignes n'est pas fluide sous GTK, ou si le thème ne peut pas approcher le look Mac, on rouvre [[ADR-002 SwiftCrossUI comme code d'interface unique]].

## P2 : Windows portable
- Un « hello world » SwiftCrossUI/GTK compilé sur Windows, avec runtime Swift et DLL GTK à côté, copié sur une clé **FAT32**.
- On le lance sur une VM Windows vierge (sans Swift, sans MSYS2).
- **On mesure** : la taille du dossier et le temps de lancement depuis la copie locale.
- **On vérifie** : l'absence d'avertissement SmartScreen ; l'éjection de la clé une fois l'app lancée via le lanceur.

## P3 : Mac portable
- `.app` ad hoc zippé, publié en release de test, téléchargé avec Safari, extrait, copié sur l'iPod, puis lancé sur **un autre Mac**.
- **On vérifie** : le comportement de Gatekeeper, la translocation, le retrait de la quarantaine par le lanceur, et l'éjection de l'iPod app ouverte.

## Résultats P1 (du 2026-10-23 au 2026-10-25)

Mesures sur 5 000 pistes, builds Release, VM Parallels (Fedora 44 : 2 vCPU, Windows 11 ARM : 4 vCPU). « Changement de section » : un clic dans la sidebar jusqu'à ce que le thread principal soit libre (`IPPM_BENCH=<tours>`).

| | macOS (AppKit) | Linux (GTK 4) | Windows (WinUI 3) |
|---|---|---|---|
| Se lance et affiche 5 000 pistes | oui | oui | oui |
| Prêt après le premier affichage | 12–40 ms | ~50 ms | ~50–70 ms |
| Changement de section | **15–17 ms** (médiane) | **51 ms** dans la VM ; 19 ms pour le même code GTK sur le Mac | **10–25 ms** dans la VM |
| Glissement de la sidebar (0,25 s) | 20–21 images, 5–7 ms de mise en page par image | 13–16 images (60 Hz) avec Vulkan ou Cairo, 6–8 ms par image ; le rendu GL de la VM cale les premiers glissements (2 images) | 16–27 images, 6 ms par image ; plus lentes quand le CPU de la VM sort du repos |
| Mode sombre | système | suit GNOME (`color-scheme`), en direct | système |
| Fenêtre sans barre, boutons façon Mac | oui (barre d'outils unifiée native) | oui (dessinés par l'app) | oui (dessinés par l'app ; zone de titre déclarée à Windows, qui déplace, agrandit et aimante la fenêtre) |
| Icônes SF Symbols | vraies, vectorielles | police locale (voir [[Risques]]) | police locale (voir [[Risques]]) |

### Ce qu'on a appris
- **Le `Table` de SwiftCrossUI ne tient pas 5 000 lignes** : un widget par cellule (30 000 vues), toutes remesurées à chaque changement d'état. Revenir à Music prenait 7 à 21 s sur Mac. Remplacé par un tableau natif virtualisé par plateforme : `NSTableView`, `GtkColumnView`, `ListView` WinUI.
- **Ne jamais retirer une grosse vue native de la fenêtre** : détacher le `NSTableView` coûtait ~60 ms (SwiftCrossUI recalcule tout l'ordre du clavier). Le tableau reste en place, les autres sections se dessinent par-dessus.
- **Chaque changement d'état remet en page toute la fenêtre** dans SwiftCrossUI. Tout ce qui est gros ou fréquent (sidebar, tableau) doit être un widget natif, hors de cette mise en page.
- Sous GTK, chaque mesure de texte recréait un contexte Pango et recalculait le CSS : corrigé par un patch local (`scripts/patch-dependencies.sh`), à proposer en amont.
- **Le glissement de la sidebar suit le même modèle sur les 3 OS** (`WindowChrome.swift`) : la seule donnée est la position du séparateur, et chaque image remet les volets en page ; les lignes de la sidebar gardent la largeur ouverte, collées au bord ; l'en-tête commence par un `TitleClearance` qui lit la largeur de la sidebar pendant la mise en page, donc le titre suit le bord sans état ni saut. L'ancienne version GTK bloquait la mise en page pendant le glissement (détail en retard, titre qui sautait).
- **Une animation fluide = une mise en page SwiftCrossUI par image, donc légère.** Sous Windows, la sidebar dessinée en SwiftCrossUI coûtait 25–35 ms par mise en page : remplacée par une `ListView` native, le glissement remet en page seulement l'en-tête du détail (~6 ms dans la VM). Le contenu de la sidebar garde sa largeur et se fait rogner par le bord (il glisse, sans se tasser) ; le titre suit le bord sans mise en page.
- Sous Windows, une tâche Swift sur le thread principal reprend avec ~100 ms de retard (la file principale de Dispatch est vidée tard par la boucle WinUI) : rien d'interactif ne doit attendre un `await`. La mesure se fait dans le dispatcher XAML.
- Les problèmes rencontrés sont détaillés dans [[Manques SwiftCrossUI]] ; la méthode dans [[Composants natifs par plateforme]].

### Ce qui reste pour clore P1
- Windows : Mica, colonnes du tableau (une ligne de texte par piste pour l'instant).
- Multisélection, tri et glisser-déposer : pas encore essayés.
- Décider de [[ADR-003 GTK et thème Mac sur Windows et Linux]], que le prototype contredit.

Le suivi tâche par tâche est dans le [GitHub Project](https://github.com/users/wwwonka/projects/5). Retour à [[Phases]].
