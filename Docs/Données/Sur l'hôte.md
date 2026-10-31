# Sur l'hôte

Décision actuelle : [[ADR-006 Application entièrement portable]].

L'hôte conserve uniquement ses fichiers média originaux. L'application lit son identité système et les dossiers configurés dans `known_hosts.json` sur l'iPod; elle ne crée ni `host.json`, ni bibliothèque, ni cache local.

La bibliothèque affichée correspond à cet hôte, mais son index est stocké sur l'iPod dans `Persistent Data/Hosts/<hostID>/library.json`. Au démarrage, le cache est chargé en mémoire et les fichiers accessibles sont affichés. Le scan en arrière-plan ajoute les fichiers nouveaux, actualise les fichiers modifiés et retire les fichiers inaccessibles. Rien ne tourne au repos.

Une ancienne bibliothèque macOS peut être lue une fois et importée sur l'iPod; l'application n'écrit jamais dans son ancien emplacement.
