# Prototypes phase 0

Une semaine pour lever les trois inconnues avant de s'engager. Chaque prototype est jetable et se fait dans un dossier `Spikes/` hors de l'app.

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

Résultats à consigner ici, puis dans les ADR concernés. Retour à [[Phases]].
