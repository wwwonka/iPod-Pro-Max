# ADR-006 — Application entièrement portable

- Statut : acceptée, 2026-10-31, décision du propriétaire.
- Remplace ADR-001 et ADR-004 pour l'emplacement des bibliothèques et caches.

L'application ne crée aucun fichier persistant sur l'ordinateur. Elle lit les médias originaux sur l'hôte; ses index, pochettes, conversions, réglages et registres résident sur l'iPod. Le lanceur exécute directement l'application sur l'iPod.

L'identifiant existant de l'OS est lu sans créer de marqueur : IOPlatformUUID sur macOS, MachineGuid sur Windows, machine-id sur Linux. Une empreinte avec espace de noms devient la clé dans `Persistent Data/known_hosts.json`. Un OS installé séparément constitue un hôte distinct. Aucun `host.json` local.

Chaque hôte garde ses sources dans `known_hosts.json` et son cache dans `Hosts/<hostID>/library.json`. On charge ce cache en mémoire, puis on compare chemins, tailles et dates de modification aux fichiers sources. Seuls les fichiers nouveaux ou modifiés nécessitent une lecture de tags. Une source inaccessible retire ses pistes du cache et de la bibliothèque, sans avertissement par piste. Son chemin reste configuré pour le prochain scan. Cette disparition n'efface jamais les chansons de l'iPod.

La première livraison transfère uniquement la sélection déposée sur l'appareil. Aucun retrait automatique, aucune sync complète avant le retour des crochets. Un manifeste sur l'appareil associe empreinte complète du fichier source, dbid, propriétaire et références des différents hôtes. Deux fichiers strictement identiques partagent une copie; des tags différents produisent des empreintes différentes.

Compromis : les premières lectures/écritures du cache dépendent de la vitesse de l'iPod. On les regroupe et l'interface travaille ensuite en mémoire. Linux nécessite un montage autorisant l'exécution; Windows peut empêcher l'éjection tant que l'application s'exécute depuis le volume. Aucune copie locale de secours n'est créée. Les traces produites par l'OS (historique, swap, etc.) ne sont pas contrôlées par l'application.
