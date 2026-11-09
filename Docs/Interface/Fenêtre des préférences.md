# Fenêtre des préférences (macOS)

Date : 2026-11-09. Voir aussi [[Refonte verre macOS]], [[Rail de médias macOS]], [[Composants natifs par plateforme]] et [[Sur l'iPod]].

## Ouverture
- C'est une vraie seconde fenêtre : une scène `Window("Settings", id: "settings")` de SwiftCrossUI, à côté du `WindowGroup`. `openWindow(id:)` l'ouvre à la demande ; elle ne s'ouvre jamais au lancement (`defaultLaunchBehavior` automatique). Les backends AppKit, GTK et WinUI gèrent plusieurs fenêtres.
- **⌘,** : `AppMenuMac` ajoutait déjà « Settings… ⌘, » au menu de l'app, mais rien n'assignait `AppCommands.openSettings` : l'item restait grisé. `ContentView` l'assigne maintenant.
- Windows et Linux : entrée « Settings… » du menu File, sans raccourci (SwiftCrossUI n'a pas de raccourcis clavier).
- La fenêtre est centrée sur l'écran de la fenêtre principale. Sa taille se règle après la première mise en page : elle reste invisible 0,25 s, est recentrée à chaque redimensionnement pendant ce temps, puis s'affiche toujours.

## Aspect (`SettingsView`, `SettingsWindowMac`)
- **Matériau** : celui de la fenêtre principale, tel que la page iPod le montre de bord en bord : le verre `underWindowBackground` posé au niveau de la fenêtre, sans teinte. Barre de titre transparente sur contenu pleine taille, titre = onglet choisi, seul le bouton de fermeture est actif.
- **Pourquoi une texture tachée au début** : un verre `behindWindow` échantillonne tout ce qui est derrière la fenêtre, autres fenêtres comprises. Avec la teinte du rail (`hudWindow` + noir 45 %), la fenêtre montrait le bleu du fond d'écran et le noir de la fenêtre principale. Sans teinte, la page iPod et Settings se ressemblent.
- **Onglets** : General (`gear`), Playback (`play.circle`), Syncing (`ipod`), Devices (`desktopcomputer`), Plug-ins (`puzzlepiece.extension`), Advanced (`wrench.and.screwdriver`). Icône de 22 pt et libellé de 11 pt, à 1 pt l'un de l'autre, comme un item de barre d'outils natif.
- **Survol** : une tuile s'éclaire sous le curseur, celle choisie est plus marquée. Les tuiles se touchent (1 pt de marge de chaque côté, dans la zone de survol et de clic) pour qu'une tuile soit toujours sous le curseur. Le backend ne suit le survol que dans la fenêtre clé (`.activeInKeyWindow`).
- **Accent** : celui du système (`NSColor.controlAccentColor`, `AppAccent`), pour l'icône comme pour le libellé, comme la sidebar. Un bleu fixe donnait un libellé plus vif que l'icône.
- Les symboles `gear`, `play.circle`, `desktopcomputer`, `puzzlepiece.extension` et `wrench.and.screwdriver` n'ont pas encore de glyphe dans la police locale de Windows et Linux (voir [[Symboles personnalisés SVG]]) : à faire correspondre avec `Tools/Build/match-glyph.swift`.

## Dossiers de la bibliothèque (onglet General)
- Une carte par section : Music, Podcasts (aucun dossier : abonnements et téléchargements restent avec la bibliothèque), Audiobooks, Videos et Photos. Chaque ligne n'affiche que le chemin et « Remove » ; « Add Folder… » ajoute sans remplacer.
- Videos se divise en quatre petites cartes : Movies, TV Shows, Music Videos, Web Videos. `SourceKind` a gagné `movies`, `tvShows`, `musicVideos` et `webVideos`. Ces dossiers sont enregistrés, pas encore importés.
- **Le sélecteur de dossier s'ouvre depuis la fenêtre Settings** (`chooseFile` de son environnement), pas depuis la principale, qui serait passée devant. La fenêtre principale ne fait que le travail : `AppCommands.addSource` et `removeSource` (`ContentView`) enregistrent la source puis relancent le scan (musique, livres audio) ou rechargent les photos.
- Le menu File → Add to Library ajoute aussi un dossier quand une bibliothèque est ouverte (le premier dossier configure encore la bibliothèque).

## Stockage et cohérence
- Les dossiers vivent dans `known_hosts.json`, sous `Persistent Data/` (l'iPod, simulé par `Build/`). `SettingsController` les relit hors du fil principal à chaque chargement de bibliothèque, donc au lancement, et la fenêtre se met à jour sur événement (aucun timer).
- La bibliothèque ne contient que ce que les dossiers contiennent : `PortableLoading.load` retire les pistes qui ne sont sous aucun dossier de musique ou de livres audio connu (un dossier retiré app fermée), et `removedKind` vide les pistes du dernier dossier d'un type retiré dans l'app. Rien n'est purgé tant qu'aucun de ces dossiers n'est configuré.
- Syncing : « Sync album artwork » écrit `syncArtwork` dans `settings.json` par `PortablePreferences.stageSyncArtwork` (écriture groupée à 500 ms).

## Vérifié, et ce qui reste
- Vérifié : build macOS, 55 tests, ouverture par le menu sans doublon, position centrée à l'ouverture, persistance de `syncArtwork` et des dossiers dans `known_hosts.json`. Test de cohérence : Audiobooks retiré de `known_hosts.json` app fermée, relance : les 13 pistes du dossier disparaissent (5312 → 5299), puis fichiers restaurés. Après nettoyage : 7 dossiers, 5312 pistes, aucune hors des dossiers connus.
- Non vérifié par moi : l'ajout et le retrait par les boutons (l'accessibilité n'atteint pas les boutons de la zone défilante), le survol entre deux onglets, le mode clair, Windows et Linux (non compilés).
- À faire : importer les dossiers vidéo, glyphes Windows et Linux, onglets Playback, Devices, Plug-ins et Advanced (vides pour l'instant), plug-ins décrits dans leur manifeste (voir [[TODO]]).
- La teinte du rail est la constante `railGlassTint` (0,55) de `MusicShell.swift`, réglée à vue.

## Pour tester en développement
Les événements souris synthétiques et le clic automatisé déplacent le curseur réel et ne suffisent pas à prouver le survol : la fenêtre doit être la fenêtre clé. Voir [[Captures d'écran en développement]].
