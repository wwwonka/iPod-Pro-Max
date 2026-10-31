# Performances de la vue par artiste

Mesures du 31 octobre 2026, même bibliothèque portable de 5 299 chansons, build debug AppKit. `IPPM_BENCH=1` mesure le délai entre le changement de sélection et le retour au repos du thread principal. Les huit premiers artistes sont visités dans le même ordre.

| Mesure | Avant | Après |
|---|---:|---:|
| Médiane des changements d’artiste | 263,5 ms | 34 ms |
| Premier artiste | 242 ms | 122 ms |
| Artistes suivants | 87–487 ms | 33–35 ms |
| Layout d’une image de l’animation du panneau latéral | ~96–102 ms | ~23–24 ms |

La page créait une arborescence SwiftCrossUI pour chaque chanson et chaque album, au-dessus de la table native. Ces lignes n’avaient aucune sélection ni source de drag. Sur macOS, une seule NSTableView virtualisée contient désormais les en-têtes d’albums et les chansons, avec cellules réutilisées. Les pochettes visibles sont réduites et décodées hors du thread principal, puis mises en cache. GTK et WinUI réutilisent leur table native virtualisée, sous le même en-tête d’artiste; les albums y figurent dans la colonne Album.

Le contrôle `IPPM_CHECK_INTERACTIONS=1` vérifie notamment une sélection de trois chansons entre deux albums et le contenu du presse-papiers privé de drag. Il n’effectue aucune écriture musicale. Les builds macOS universel, Linux x86_64/aarch64 et Windows ARM64 passent, ainsi que les 51 tests du noyau. La vérification manuelle du nouveau build avec l’outil de contrôle de l’écran n’a pas pu être terminée (expiration de l’outil); elle ne fait pas partie de ces preuves.

Les mesures précèdent l’ajout du menu natif d’envoi d’album et du filtrage par recherche. Aucun de ces contrôles ne crée de widgets pour les lignes hors écran.
