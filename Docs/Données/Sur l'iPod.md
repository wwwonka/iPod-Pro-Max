# Sur l'iPod

Ce qui concerne **l'iPod lui-même** voyage avec lui. Décision : [[ADR-001 Bibliothèque sur l'hôte, données de l'iPod sur l'iPod]].

`Build/` reproduit exactement cette disposition (voir plus bas) : le build ne touche jamais un vrai iPod.

```
<iPod>/
├─ LAUNCHER.bat             lanceur polyglotte sh + cmd (Windows : double-clic ; Linux : sh LAUNCHER.bat)
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
   └─ Persistent Data/      bibliothèques, caches, réglages et registres, partagés par les 3 OS
      ├─ device.json     options de sync de cet iPod (en place)
      ├─ cli-sync.json   registre de sync de la CLI (en place)
      ├─ settings.json   préférences communes aux trois interfaces
      ├─ known_hosts.json   identité, nom et dossiers sources de chaque hôte
      ├─ manifest.json   transferts : dbid, propriétaire, empreinte source et références
      └─ Hosts/<hostID>/
         ├─ library.json   cache des pistes accessibles, playlists et chemins sources
         ├─ Artwork/       pochettes dédupliquées
         └─ Transcodes/    conversions audio réutilisables
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

Voir [[ADR-006 Application entièrement portable]]. Tout le stockage de l'application voyage sur l'iPod. `known_hosts.json` conserve les dossiers par catégorie (musique, audiolivres, vidéos, photos); seule la musique est raccordée dans cette livraison. Le bouton + configure son dossier et la flèche circulaire relance le scan. Les pistes inaccessibles disparaissent, leurs chemins sources restent connus.

`manifest.json` mémorise les transferts et évite les doublons de fichiers identiques entre hôtes. Le dépôt de chansons ajoute uniquement la sélection et conserve les autres pistes, playlists et pochettes. Le bouton Sync reste désactivé en attendant les crochets par chanson.

`device.json` et `cli-sync.json` restent compatibles. Les réglages actuellement partagés par `settings.json` sont le mode d'affichage musical et l'activation des pochettes; les fonctions futures ajouteront leurs préférences lorsqu'elles seront raccordées.

## Réactivité
- Les réglages et registres sont petits; le cache de bibliothèque peut atteindre plusieurs Mo. On les lit en arrière-plan et on les garde en mémoire. Le cache est vérifié contre les sources au démarrage puis sur action explicite.
- On les écrit **par lots** : avant une sync, avant une éjection et à la fermeture. Jamais à chaque modification, parce que le disque dur de l'iPod se met en veille et le réveiller coûte des secondes.
- **Écriture sûre** (FAT32 n'a pas de journal) : on écrit `x.json.tmp`, on fait `fsync`, on renomme, et on garde `x.json.bak` (génération précédente). Au chargement, si `x.json` est illisible, on prend `.bak`.

Objectif mesuré : données de l'iPod disponibles moins de 300 ms après le montage (voir [[Phases]]).

## Déjà en place
- Le CLI écrit son registre de sync dans `Persistent Data/cli-sync.json` avec l'écriture sûre décrite plus haut (`DeviceDataFolder` dans iPodKit). Voir [[CLI ipodpromax]].
- La page iPod de l'app écrit ses options de sync dans `Persistent Data/device.json` de cet iPod, 2 s après le dernier changement (une rafale de clics ne réveille le disque qu'une fois).

Les fichiers `autorun.inf`, `.VolumeIcon.icns`, `.VolumeIcon.ico`, `.VolumeIcon.png` et `.directory` sont masqués et verrouillés à l’assemblage. `iPod_Control` est masqué, mais reste modifiable pour les transferts. Le seul lanceur distribué est `LAUNCHER.bat`.
