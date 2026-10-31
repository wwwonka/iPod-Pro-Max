# Migration

Elle s'exécute une seule fois par ordi et par iPod, sans rien perdre, et on peut revenir en arrière.

## Au premier lancement de la nouvelle version
1. **Bibliothèque** : `library.json` reste dans `Application Support`, où elle est déjà. On crée `host.json` (identifiant de l'ordi). Voir [[Sur l'hôte]].
2. **Caches** : `Transcodes/` et `PhotoCache/` sont **déplacés** (simple `rename`, sur le même volume) vers `~/Library/Caches/iPod Pro Max`. C'est instantané, sans recopier les 14 Go.
3. **Empreintes** : calculées en arrière-plan, en parallèle, priorité `.utility`, pour les pistes qui n'en ont pas. Voir [[Empreinte audio]].

## Au premier branchement de chaque iPod
1. Si `iPod Pro Max/Data/` n'existe pas, on le crée à partir de :
   - `deviceRecords[deviceID]` dans `library.json`, qui donne `device.json` et le manifeste ;
   - `UserDefaults`, qui donne `settings.json` ;
   - `shows` dans `library.json`, qui donne `podcasts.json`.
2. **Manifeste initial** : chaque `trackDBIDs[uuid] = dbid` existant devient une entrée dont l'hôte courant est propriétaire.
3. `deviceRecords` reste dans `library.json` pendant une version (lecture seule), pour pouvoir revenir à l'ancienne version.

## Compatibilité
On reprend le mécanisme existant `LibraryStore.backfillMissingKeys` : tout nouveau champ non optionnel est complété dans le JSON brut avant le décodage. Chaque fichier de `Data/` porte un champ `version`.
