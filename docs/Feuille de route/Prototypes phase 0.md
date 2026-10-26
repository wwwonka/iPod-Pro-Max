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
| Changement de section | **15–17 ms** (médiane) | **51 ms** dans la VM ; 19 ms pour le même code GTK sur le Mac | pas encore mesuré |
| Glissement de la sidebar (0,25 s) | 21–26 images | **à reprendre** : fermeture 9–10 images, démarrée ~670 ms après le clic ; ouverture ~870 ms (au mieux 16–19 images avant les derniers changements) | pas encore |
| Mode sombre | système | suit GNOME (`color-scheme`), en direct | système |
| Fenêtre sans barre, boutons façon Mac | oui (barre d'outils unifiée native) | oui (dessinés par l'app) | **pas encore** |
| Icônes SF Symbols | vraies, vectorielles | police locale (voir [[Risques]]) | pas encore |

### Ce qu'on a appris
- **Le `Table` de SwiftCrossUI ne tient pas 5 000 lignes** : un widget par cellule (30 000 vues), toutes remesurées à chaque changement d'état. Revenir à Music prenait 7 à 21 s sur Mac. Remplacé par un tableau natif virtualisé par plateforme : `NSTableView`, `GtkColumnView`, `ListView` WinUI.
- **Ne jamais retirer une grosse vue native de la fenêtre** : détacher le `NSTableView` coûtait ~60 ms (SwiftCrossUI recalcule tout l'ordre du clavier). Le tableau reste en place, les autres sections se dessinent par-dessus.
- **Chaque changement d'état remet en page toute la fenêtre** dans SwiftCrossUI. Tout ce qui est gros ou fréquent (sidebar, tableau) doit être un widget natif, hors de cette mise en page.
- Sous GTK, chaque mesure de texte recréait un contexte Pango et recalculait le CSS : corrigé par un patch local (`scripts/patch-dependencies.sh`), à proposer en amont.
- Les problèmes rencontrés sont détaillés dans [[Manques SwiftCrossUI]] ; la méthode dans [[Composants natifs par plateforme]].

### Ce qui reste pour clore P1
- Windows : fenêtre sans bordure, Mica, colonnes du tableau (une ligne de texte par piste pour l'instant).
- Le contenu de la sidebar doit glisser, pas se tasser, pendant l'animation.
- Linux : rendre le glissement de la sidebar fluide à chaque fois. Laisser `shrink-start-child` activé coupe la sidebar par la gauche ; l'activer seulement pendant l'animation coûte une mise en page complète à chaque bascule.
- Multisélection, tri et glisser-déposer : pas encore essayés.
- Décider de [[ADR-003 GTK et thème Mac sur Windows et Linux]], que le prototype contredit.

Le suivi tâche par tâche est dans le [GitHub Project](https://github.com/users/wwwonka/projects/5). Retour à [[Phases]].
