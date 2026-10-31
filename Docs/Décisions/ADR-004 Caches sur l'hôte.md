# ADR-004 Caches sur l'hôte

- **Statut** : acceptée, le 2026-10-22
- **Contexte** : `Transcodes` (14 Go), `PhotoCache` (115 Mo) et les épisodes de podcast (5,3 Go) sont aujourd'hui dans `Application Support`. Ce sont des fichiers reconstructibles, et l'iPod contient déjà le résultat final de chaque transcodage.
- **Décision** : ces caches vont dans le **dossier de cache de l'OS** de l'hôte (`~/Library/Caches`, `%LOCALAPPDATA%`, `$XDG_CACHE_HOME`), jamais sur l'iPod. La migration les déplace par simple renommage (voir [[Migration]]).
- **Conséquences** :
  - environ 19 Go en moins dans les sauvegardes (Time Machine exclut `Caches`) ;
  - l'OS peut les vider ; l'app les reconstruit au besoin, au prix d'un transcodage à la prochaine sync de la piste concernée.

Voir [[Sur l'hôte]].
