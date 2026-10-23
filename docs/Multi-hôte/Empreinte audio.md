# Empreinte audio

Elle permet de reconnaître **la même chanson** d'un ordi à l'autre, même si le chemin, le nom de fichier ou les tags diffèrent. Elle sert au [[Manifeste et propriété des pistes]] et à l'[[Onglet iPod]] (« déjà dans ma bibliothèque ? »).

## Définition
`empreinte = SHA-256(flux audio sans tags) · durée (ms, arrondie) · taille du flux`
- **Sans les tags** : éditer un titre ou une pochette ne change pas l'empreinte. On saute l'en-tête ID3v2 et l'ID3v1 final, les atomes `moov/udta/meta` en MP4, et les blocs de métadonnées FLAC. Le lecteur de tags de [[MediaKit]] connaît déjà ces structures.
- **Échantillonnée** pour la vitesse : on hashe 3 fenêtres de 256 Ko (début, milieu, fin) du flux audio, plus sa taille exacte. On lit environ 768 Ko par fichier au lieu du fichier entier.
- **Source et copie iPod** : si la piste a été transcodée, le fichier sur l'iPod a une autre empreinte. Le manifeste stocke donc **l'empreinte de la source**, et l'empreinte du fichier iPod si elle diffère.

## Calcul
- À l'import, dans la même tâche parallèle que la lecture des tags (`importFiles`) : pas de passe disque supplémentaire.
- Pour la bibliothèque existante : en arrière-plan, priorité `.utility`, fenêtre glissante d'environ `activeProcessorCount / 2` tâches (travail limité par le disque).
- On mesure avec `dbtest --import-bench` : le surcoût doit rester sous 10 %.
