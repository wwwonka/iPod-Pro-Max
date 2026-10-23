# Sur l'iPod

Ce qui concerne **l'iPod lui-même** voyage avec lui. Décision : [[ADR-001 Bibliothèque sur l'hôte, données de l'iPod sur l'iPod]].

```
<iPod>/
├─ iPod_Control/            (inchangé : iTunesDB, ArtworkDB, Music/F00…F49)
└─ iPod Pro Max/
   ├─ App/
   │  ├─ macOS/iPod Pro Max.app        universel, signé ad hoc
   │  ├─ Windows/iPod Pro Max.exe + DLL (runtime Swift, GTK4)
   │  ├─ Linux/ipod-pro-max + lancer.sh + .desktop
   │  └─ version.txt
   ├─ Tools/
   │  ├─ macOS/ffmpeg, yt-dlp
   │  ├─ Windows/ffmpeg.exe, yt-dlp.exe
   │  └─ Linux/ffmpeg, yt-dlp
   └─ Data/
      ├─ settings.json   réglages portables
      ├─ device.json     options de sync de cet iPod
      ├─ manifest.json   propriété des pistes (dbid → hôte, empreinte, id source)
      └─ podcasts.json   abonnements
```

## Contenu de `Data/`
- **`settings.json`** : ce qui est aujourd'hui dans `UserDefaults` et `@AppStorage`, à savoir `ejectAfterSync`, `syncArtwork`, `defaultKeepLatest`, `youtubeCookiesBrowser`, `scanLibraryOnLaunch`, `musicViewMode` et l'ordre de la sidebar. L'état de fenêtre (taille, dernier onglet) reste dans les préférences de l'hôte.
- **`device.json`** : la partie « choix » de `DeviceSyncRecord` (`syncAllMusic`, `selectedPlaylistIDs`, `syncPodcasts`, `syncVideos`, `syncPhotos`, `syncAudiobooks`, `useAlbumArtistForGrouping`). Les correspondances UUID → dbid passent dans le manifeste.
- **`manifest.json`** : voir [[Manifeste et propriété des pistes]].
- **`podcasts.json`** : on s'abonne une fois, et tous les ordis rafraîchissent les mêmes émissions. Les épisodes téléchargés transitent par le cache de l'hôte (voir [[Sur l'hôte]]).

## Réactivité
- Ces fichiers sont petits (quelques centaines de Ko au plus). On les lit **une fois au branchement**, en arrière-plan, et on les garde en mémoire.
- On les écrit **par lots** : avant une sync, avant une éjection et à la fermeture. Jamais à chaque modification, parce que le disque dur de l'iPod se met en veille et le réveiller coûte des secondes.
- **Écriture sûre** (FAT32 n'a pas de journal) : on écrit `x.json.tmp`, on fait `fsync`, on renomme, et on garde `x.json.bak` (génération précédente). Au chargement, si `x.json` est illisible, on prend `.bak`.

Objectif mesuré : données de l'iPod disponibles moins de 300 ms après le montage (voir [[Phases]]).
