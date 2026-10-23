# Manifeste et propriété des pistes

## Le problème
Aujourd'hui, `DeviceSyncRecord.trackDBIDs` (`Library/LibraryModels.swift:187`) associe les UUID de **la** bibliothèque aux dbid de l'iPod. Avec une bibliothèque par ordi :
- l'ordi B ne connaît pas les UUID de l'ordi A. Il voit donc les pistes de A comme « inconnues » ;
- avec `removeUnknownTracks`, une sync depuis B **effacerait la musique de A** ;
- sans cette option, B **dupliquerait** les chansons que A a déjà mises.

## La solution : `manifest.json` sur l'iPod
```json
{
  "version": 1,
  "hosts": { "<hostID>": { "name": "MacBook de Julien", "lastSync": "2026-10-22T…" } },
  "tracks": {
    "<dbid>": { "owner": "<hostID>", "sourceID": "<UUID dans la bibliothèque de l'hôte>",
                "fingerprint": "<empreinte audio>", "addedAt": "…" }
  },
  "playlists": { "<playlistID iPod>": { "owner": "<hostID>", "sourceID": "<UUID>" } }
}
```

## Règles de sync depuis l'ordi X
1. **Pistes de X** : gérées comme aujourd'hui (ajout, mise à jour des tags, retrait si désélectionnée).
2. **Piste sans propriétaire, mais avec une empreinte qui correspond** à une piste de X : on **l'adopte** (X en devient propriétaire). Pas de copie, pas de doublon.
3. **Pistes d'un autre ordi** : **jamais** supprimées ni modifiées par une sync. Elles restent dans le DB réécrit, tags et compteurs intacts.
4. **Pistes inconnues** (sans entrée, mises par iTunes ou un autre outil) : `removeUnknownTracks` ne s'applique qu'à elles, comme aujourd'hui.
5. Les **playlists** suivent la même règle de propriété.

On ne modifie ou ne supprime une piste d'un autre ordi qu'explicitement, depuis l'[[Onglet iPod]].

## Compteurs de lecture
`Play Counts` est lu par la sync en cours et rendu à la bibliothèque **du propriétaire**, si c'est l'ordi courant. Sinon, le compteur reste dans l'iTunesDB, et le propriétaire le récupère à sa prochaine sync, puisqu'il est conservé dans le DB.

Voir aussi [[Empreinte audio]] et [[Sur l'iPod]].
