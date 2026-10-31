# Navigation, interactions et caches des vues

Mesures du 31 octobre 2026 sur le même Mac, build debug AppKit, bibliothèque portable de 5 299 chansons, un abonnement podcast et 13 chapitres de livres audio. `IPPM_BENCH_VIEWS=1 IPPM_PORTABLE_ROOT="$PWD/Build" .build/debug/iPodProMaxApp` visite trois fois les sections et les iPods connectés. Le délai va du changement de sélection au retour au repos du thread principal; il inclut la reconstruction et le layout, pas seulement les lectures disque.

| Vue | Avant les derniers ajustements de layout, médiane de 3 visites | Après |
|---|---:|---:|
| iPod simulé | 290 ms | 103 ms |
| Photos | 145 ms | 82 ms |
| Musique, toutes les chansons | 62 ms | 51 ms |
| Podcasts | 78 ms | 80 ms |
| Livres audio | 38 ms | 40 ms |
| Vidéos, état vide | 26 ms | 26 ms |

Ces mesures isolées restent sensibles à la charge de la machine; elles ne prouvent pas une accélération des vues dont les temps sont similaires. La sélection de trois artistes prend environ 33–35 ms dans le benchmark de navigation. Les premières créations restent plus coûteuses que les mises à jour suivantes.

## Choix retenus

- Les listes natives d’artistes utilisent un ensemble d’identifiants et les gestes de sélection de la plateforme. Le détail combine les albums dans l’ordre de la liste, et le drag contient les chansons de tous les artistes sélectionnés. Le choix d’une photo reste réservé à un artiste unique.
- La table de chansons conservée sous les autres sections est explicitement masquée et désactivée. Sa source de drag refuse toute demande quand elle est inactive; le jeton précédent est annulé. Le retour aux podcasts crée un nouveau jeton valide.
- `RetainedPage` conserve les composants et l’état d’une page iPod après sa première visite, et détache la page inactive. Aucune mise en page n’est faite pour son contenu inactif. Le cache appartient au graphe de vues et disparaît lorsque l’iPod est retiré. La même stratégie ralentissait Photos lors de l’essai et n’y est pas utilisée.
- Photos conserve un inventaire par bibliothèque d’hôte, déduplique les chargements simultanés et parcourt les dossiers en parallèle avec une fenêtre dimensionnée selon le nombre de cœurs. Refresh, l’ajout/retrait d’une source et la demande d’accès Photos renouvellent l’inventaire. Une publication groupée remplace les mises à jour séparées des dossiers, comptes et albums.
- Les abonnements podcasts utilisent la liste native; les compteurs et les épisodes choisis par la règle de conservation sont mis en cache par révision de contenu. Les notifications de progression ne reconstruisent pas le modèle d’abonnements.
- macOS et GTK partagent leurs miniatures entre vues, dédupliquent leur décodage et limitent le cache à 32 Mio. Le décodage/redimensionnement utilise une file utility, limitée à la moitié des cœurs disponibles. Les textures GTK immuables sont utilisables entre threads, conformément à la [documentation GDK](https://docs.gtk.org/gdk4/class.Texture.html). WinUI utilise le chargement URI de BitmapImage avec une taille de décodage adaptée et évite de recréer l’image quand son URL n’a pas changé.

## Vérifications

Sur trois visites successives des sections, le benchmark constate **zéro lecture supplémentaire des pages iPod et zéro scan Photos supplémentaire** après leur chargement initial. Les contrôles natifs `IPPM_CHECK_INTERACTIONS=1` couvrent sélection et drag multi-artiste, sélection entre albums, refus du drag depuis une table cachée, reprise du drag au retour, partage des miniatures, un seul scan Photos pour des requêtes simultanées, actualisation explicite et isolation des caches entre hôtes. Ils utilisent un presse-papiers privé et des dossiers temporaires; aucun média utilisateur n’est transféré.

Une instance macOS de test distincte a permis de vérifier les gestes réels : Cmd-clic ajoute un deuxième artiste (cinq albums, 46 chansons dans le cas testé), puis Shift-clic étend à une plage de quatre artistes (16 albums, 183 chansons). Après sélection d’un épisode, la page iPod ne présente plus la table de podcasts dans son arbre d’accessibilité; un clic-drag dans sa zone vide ne change pas cet état. Le retour aux podcasts conserve l’épisode sélectionné. Aucun dépôt sur un iPod ni transfert de média n’a été effectué pour cet essai.

La suite partagée passe ses 51 tests; les contrôles natifs supplémentaires passent également. Les builds macOS universel (Intel et Apple Silicon), Linux x86_64/aarch64 et Windows ARM64 sont vérifiés. Les gestes à l’écran ont été vérifiés sur macOS; les gestes natifs Linux et Windows ne sont pas certifiés par cet essai.
