# Sur l'iPod

Ce qui concerne **l'iPod lui-même** voyage avec lui. Décision : [[ADR-001 Bibliothèque sur l'hôte, données de l'iPod sur l'iPod]].

`Build/` reproduit exactement cette disposition (voir plus bas) : le build ne touche jamais un vrai iPod.

```
<iPod>/
├─ LAUNCHER.cmd             lanceur polyglotte sh + cmd (Windows : double-clic ; Linux : sh LAUNCHER.cmd)
├─ LAUNCHER.command         le même fichier, pour le double-clic sur macOS
├─ LISEZMOI.txt             et tout ce que contient Distribution/iPod Root/
├─ iPod_Control/            (inchangé : iTunesDB, ArtworkDB, Music/F00…F49)
└─ iPod Pro Max/
   ├─ Applications/
   │  ├─ macOS/iPod Pro Max.app             universel, macOS 10.15.4 et plus, signé ad hoc
   │  ├─ Windows/x64|arm64/                 iPodProMaxApp.exe + DLL + ffmpeg.exe
   │  └─ Linux/x86_64|aarch64/              iPodProMaxApp + ffmpeg
   ├─ Command Line/
   │  ├─ macOS/ipodpromax                   universel, + ffmpeg
   │  ├─ Windows/x64|arm64/ipodpromax.exe   + DLL du runtime Swift + ffmpeg.exe
   │  └─ Linux/x86_64|aarch64/ipodpromax    entièrement statique (musl), + ffmpeg
   ├─ version.txt           change à chaque build : le lanceur recopie alors l'app
   └─ Persistent Data/      réglages et registres, partagés par les 3 OS
      ├─ device.json     options de sync de cet iPod (en place)
      ├─ cli-sync.json   registre de sync de la CLI (en place)
      ├─ settings.json   réglages portables (à venir)
      ├─ manifest.json   propriété des pistes (dbid → hôte, empreinte, id source)
      └─ podcasts.json   abonnements
```

ffmpeg est posé à côté de chaque exécutable (là où `FFmpeg.binaryPath()` regarde en premier) : la copie locale faite par le lanceur l'emporte avec elle, et chaque architecture a le sien. `Persistent Data/` s'appelait `Data/` jusqu'au 2026-10-31 ; l'ancien dossier est encore lu, jamais écrit.

## `Build/`, un iPod simulé
`Tools/Build/build.sh` (ou `Build.command`) compile chaque OS dans `.build-work/`, puis `Tools/Build/assemble-ipod.sh` remplit `Build/` :
- `Distribution/iPod Root/` est copié tel quel à la racine (ajouts et mises à jour, jamais de suppression : ce qu'on synchronise dans `Build/` reste) ;
- `Applications/` et `Command Line/` sont des miroirs de `.build-work/` ;
- `iPod_Control/` est **généré s'il est absent** (`ipodpromax init-sim`, ou copié depuis `Distribution/iPod Root/iPod_Control/`), **puis jamais touché** ;
- `Persistent Data/` n'est jamais touché ;
- `--clean` repart de zéro, ces deux dossiers compris.

L'app lancée depuis `Build/` (par le lanceur ou directement) y voit un iPod simulé : `PortableRoot` dans `iPod Pro Max/Platforms/`.

## Contenu de `Persistent Data/`
- **`settings.json`** : ce qui est aujourd'hui dans `UserDefaults` et `@AppStorage`, à savoir `ejectAfterSync`, `syncArtwork`, `defaultKeepLatest`, `youtubeCookiesBrowser`, `scanLibraryOnLaunch`, `musicViewMode` et l'ordre de la sidebar. L'état de fenêtre (taille, dernier onglet) reste dans les préférences de l'hôte.
- **`device.json`** : la partie « choix » de `DeviceSyncRecord` (`syncAllMusic`, `selectedPlaylistIDs`, `syncPodcasts`, `syncVideos`, `syncPhotos`, `syncAudiobooks`, `useAlbumArtistForGrouping`). Les correspondances UUID → dbid passent dans le manifeste.
- **`manifest.json`** : voir [[Manifeste et propriété des pistes]].
- **`podcasts.json`** : on s'abonne une fois, et tous les ordis rafraîchissent les mêmes émissions. Les épisodes téléchargés transitent par le cache de l'hôte (voir [[Sur l'hôte]]).

## Réactivité
- Ces fichiers sont petits (quelques centaines de Ko au plus). On les lit **une fois au branchement**, en arrière-plan, et on les garde en mémoire.
- On les écrit **par lots** : avant une sync, avant une éjection et à la fermeture. Jamais à chaque modification, parce que le disque dur de l'iPod se met en veille et le réveiller coûte des secondes.
- **Écriture sûre** (FAT32 n'a pas de journal) : on écrit `x.json.tmp`, on fait `fsync`, on renomme, et on garde `x.json.bak` (génération précédente). Au chargement, si `x.json` est illisible, on prend `.bak`.

Objectif mesuré : données de l'iPod disponibles moins de 300 ms après le montage (voir [[Phases]]).

## Déjà en place
- Le CLI écrit son registre de sync dans `Persistent Data/cli-sync.json` avec l'écriture sûre décrite plus haut (`DeviceDataFolder` dans iPodKit). Voir [[CLI ipodpromax]].
- La page iPod de l'app écrit ses options de sync dans `Persistent Data/device.json` de cet iPod, 2 s après le dernier changement (une rafale de clics ne réveille le disque qu'une fois).
