# Renommer un volume FAT32 avec des majuscules et des minuscules

Recherche du 1er novembre 2026. Le propriétaire souhaite remettre cette fonctionnalité à plus tard : ce document conserve les résultats et une piste, pas une implémentation livrée ni une décision technique définitive.

## Objectif

Depuis macOS, Windows ou Linux, renommer un iPod FAT32 avec un nom comme « iPod Julien » et retrouver cette casse après éjection et reconnexion. Le nom dans l'interface et l'iTunesDB et le nom du volume visible par le système sont deux choses distinctes. Le renommage existant dans `DeviceView.rename` modifie l'iTunesDB, mais pas l'étiquette du volume.

L'application peut être exécutée depuis l'iPod. Elle doit rester utilisable normalement et ne faire aucun travail périodique dans l'attente d'une éjection.

## Parcours envisagé

L'utilisateur saisit le nom une seule fois. L'interface et l'iTunesDB sont mises à jour ; une demande durable de renommage du volume est enregistrée sur l'iPod, avec un état « en attente de l'éjection ». Lors de l'éjection demandée dans l'application : terminer ou refuser les transferts actifs, enregistrer les préférences et fermer les accès nécessaires, identifier précisément la partition, démonter sans forcer, modifier l'étiquette FAT32, synchroniser et vérifier les écritures, puis terminer l'éjection. Ne déclarer le changement réussi qu'après vérification ; conserver et signaler explicitement les demandes en attente ou les réussites partielles.

Quand l'exécutable tourne depuis l'iPod, il peut empêcher le démontage. Une piste est de démarrer un petit auxiliaire depuis l'ordinateur, puis de fermer l'application au moment de l'éjection pour lui laisser terminer l'opération. Son fonctionnement, sa distribution et ses autorisations restent à démontrer sur les trois OS. La fermeture seule ne doit pas éjecter implicitement un iPod que l'utilisateur continue d'utiliser. Un débranchement sans éjection ne permet pas de garantir l'opération : conserver la demande pour une éjection ultérieure.

Une autre piste est d'exécuter dès le départ une copie locale de l'application, avec la racine des données portables explicitement pointée vers l'iPod. Elle pourrait rester ouverte pendant le démontage, mais elle introduit du coût et de la complexité ; ne pas la considérer comme choisie. Les deux pistes exigent de traiter les fichiers ouverts par d'autres applications, les permissions, les annulations et les échecs de remontage ou d'éjection.

## Principe FAT32

La méthode du [fil MacRumors](https://forums.macrumors.com/threads/upper-and-lowercase-in-a-fat32-volume-name.677658/) écrit directement les octets du nom dans le secteur de démarrage et dans l'entrée de volume du répertoire racine. L'emplacement de cette entrée dépend du volume : ne jamais utiliser l'adresse fixe donnée dans l'exemple du forum. Le prototype local calcule la disposition et modifie aussi le secteur de démarrage de secours lorsqu'il est présent et cohérent.

Une étiquette FAT occupe 11 octets. Les caractères acceptés et leur encodage doivent être définis et validés explicitement ; le prototype est volontairement limité à 1–11 caractères ASCII (lettres, chiffres, espaces internes, tiret et souligné). Les noms plus longs, accents et autres caractères restent à concevoir. Le comportement des systèmes et de l'iPod avec des minuscules non standard doit être vérifié, sans promettre un affichage identique partout.

## Résultats observés

- **Image FAT32 hors ligne, macOS :** l'écriture directe d'`iPod Julien` dans l'étiquette racine et les secteurs de démarrage a produit une image que le propriétaire a montée et remontée dans le Finder avec la bonne casse. `fsck.fat -n` ne signalait pas d'erreur. Une copie a aussi été attachée comme périphérique virtuel, modifiée démontée, puis montée sous le nom `iPod Test`.
- **mtools :** `mlabel` a écrit la casse mixte dans le secteur de démarrage mais créé une étiquette courte en majuscules avec une entrée de nom long. Le propriétaire a constaté l'affichage en majuscules dans le Finder pour cette image.
- **Renommage natif macOS à chaud :** sur une image FAT32 standard, `diskutil rename` a affiché `Mon iPod` pendant le montage mais enregistré `MON IPOD` dans l'étiquette racine et le secteur de démarrage. Le [code source publié par Apple](https://github.com/apple-oss-distributions/msdosfs/blob/main/msdosfs.kextproj/msdosfs.kmodproj/msdosfs_vfsops.c) montre la conversion et l'écriture du nom. Une autre image, déjà modifiée pour la casse mixte, est revenue à l'ancien nom après remontage : ne pas généraliser ce cas.
- **Écriture brute à chaud sur macOS :** `/dev/disk8` a renvoyé `Resource busy` ; `/dev/rdisk8` a accepté l'écriture sur l'image jetable montée. Après démontage, l'ancienne étiquette racine était revenue alors que le secteur de démarrage gardait la nouvelle ; `fsck.fat -n` signalait leur divergence. Reproduit sans activité volontaire et avec création d'un fichier. Synchroniser d'abord le répertoire a fonctionné dans un essai sans activité ultérieure, mais a échoué après création et synchronisation d'un fichier. Ne pas déduire qu'une écriture brute sur volume monté est sûre.
- **Fedora Linux :** sur une image loop montée, une écriture brute suivie de la création d'un fichier, d'un `sync` et d'un démontage a conservé `iPod Linux` ; `fsck.fat -n` était propre. C'est un seul scénario, pas une preuve de sûreté sous accès concurrents.
- **Windows :** la VM répondait, mais la session testée n'avait pas les droits administrateur pour créer et monter le disque virtuel ; aucun essai FAT32 n'a été réalisé. La documentation de [`SetVolumeLabel`](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setvolumelabela) mentionne la limite FAT de 11 caractères sans garantir la conservation de la casse.
- **Exécutable sur le volume, macOS :** un petit programme actif lancé depuis une image montée empêchait son démontage ; le même programme lancé depuis l'hôte permettait le démontage. Ce n'est pas encore un test de l'application complète.

Aucun iPod physique n'a été modifié durant ces essais. Les images de `/tmp/ipod-fat-test.*` sont temporaires et ne constituent pas des artefacts durables.

## Prototype et validation future

Les prototypes expérimentaux locaux se trouvent dans `Tools/FAT32Label/` : `prepare-test-image.py`, ses tests Python et `test-linux-mounted.sh`. Ils ne sont pas intégrés à l'application et ne sont pas un outil de renommage de disque physique. Vérifier leur présence dans le checkout avant de les utiliser.

Avant une mise en service : tests sur images et périphériques virtuels pour chaque OS, puis sur iPod physique ; test de reconnexion et d'affichage dans les systèmes et sur l'iPod ; coordination exclusive avec transferts et préférences ; validation de l'identité de la partition et des permissions ; contrôle des échecs d'écriture, déconnexion, éjection refusée, remontage et récupération. L'accès direct sur volume monté exige une preuve de coordination avec le pilote, pas seulement une relecture immédiate des octets.
