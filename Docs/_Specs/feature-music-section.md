# Section Musique : spec de finition

Source : « TODO - section Musique » (13 novembre 2026) et les six captures d'écran d'iTunes 12 (une par onglet) pour le Metadata Editor.

## Cadre

- **Périmètre** : sept chantiers de finition de la section Musique, découpés en sous-tâches numérotées MUS-1 à MUS-32.
- **Plateformes** : chaque sous-tâche sort sur macOS, Windows et Linux ensemble. Les raccourcis sont donnés en notation macOS ; sur Windows et Linux, Ctrl remplace ⌘.
- **Performance** : aucune de ces fonctions ne doit ajouter de travail au repos ni d'accès disque par ligne ou par rendu. Les pochettes floutées, les animations de glisser et les survols sont calculés une fois puis mis en cache.
- **Statut du contenu** : les rubriques Objectifs, Comportement utilisateur, Règles d'interaction et États visuels reprennent le TODO. Les Edge cases et tout ce qui est marqué « à confirmer » sont des propositions à valider, absentes de la source.

## Vue d'ensemble

| Section | Sous-tâches |
| --- | --- |
| 1. Recently Added | MUS-1 |
| 2. Favorites | MUS-2, MUS-3 |
| 3. Columns | MUS-4, MUS-5 |
| 4. Sidebar Reorder | MUS-6 à MUS-9 |
| 5. Albums View | MUS-10 à MUS-15 |
| 6. Playlists | MUS-16 à MUS-20 |
| 7. Metadata Editor | MUS-21 à MUS-32 |

---

## 1. Recently Added

### Objectifs

Montrer les ajouts récents dans le même format que le reste de la bibliothèque, pour qu'on puisse les trier, les sélectionner et les glisser comme n'importe quelle liste de morceaux.

### Sous-tâches

- **MUS-1** : afficher la vue Recently Added en vue liste.

### Comportement utilisateur

- L'utilisateur ouvre Recently Added et voit une liste de morceaux, les plus récents en haut.
- Il retrouve les mêmes colonnes, la même sélection et les mêmes menus contextuels que dans les autres vues liste.

### Règles d'interaction

- Le tri par défaut est la date d'ajout, décroissante.
- Les colonnes visibles suivent le réglage global décrit en section 3.
- Un clic sur un en-tête de colonne change le tri, comme dans les autres vues liste.

### États visuels

- **Par défaut** : liste triée par date d'ajout.
- **Vide** : message court indiquant qu'aucun morceau n'a été ajouté récemment.
- **Import en cours** : les nouveaux morceaux apparaissent par lots, sans faire sauter la position de défilement.

### Edge cases

- Un tri choisi par l'utilisateur est-il conservé à la prochaine ouverture, ou la vue revient-elle toujours à la date d'ajout ? À confirmer.
- La fenêtre de temps ou le nombre de morceaux qui définit « récent » n'est pas précisé. À confirmer.
- Plusieurs morceaux importés à la même seconde : l'ordre secondaire suit album puis numéro de piste, pour garder les albums groupés.

---

## 2. Favorites

### Objectifs

Permettre de marquer un morceau comme favori d'un geste, avec un symbole reconnaissable, et laisser l'utilisateur choisir ce symbole : cœur ou étoile.

### Sous-tâches

- **MUS-2** : afficher l'état favori avec une icône cliquable pour basculer, par défaut le SF Symbol heart.
- **MUS-3** : ajouter dans Settings un réglage qui change l'icône des favoris entre heart et star.

### Comportement utilisateur

- L'utilisateur clique l'icône d'un morceau pour l'ajouter aux favoris, et clique de nouveau pour le retirer.
- Dans Settings, il choisit entre le cœur et l'étoile ; toute l'interface adopte aussitôt l'icône choisie.

### Règles d'interaction

- Un clic sur l'icône bascule l'état sans modifier la sélection ni lancer la lecture.
- Avec plusieurs morceaux sélectionnés, basculer l'icône de l'un applique le nouvel état à toute la sélection.
- Le réglage ne change que l'apparence : les favoris enregistrés restent les mêmes d'une icône à l'autre.
- L'icône choisie s'applique partout où un favori apparaît : vues liste, vue Albums, Metadata Editor, menus.
- Le changement de réglage s'applique immédiatement, sans relance, et il est conservé entre les sessions.

### États visuels

- **Non favori** : icône en contour (heart ou star), discrète.
- **Favori** : icône pleine (heart.fill ou star.fill), couleur d'accent.
- **Survol** : l'icône en contour gagne en contraste pour signaler qu'elle est cliquable.
- **Settings** : choix entre deux options, chacune illustrée par son icône ; l'option active est mise en évidence.

### Edge cases

- Icône étoile et note sur cinq étoiles : dans le Metadata Editor, le favori est placé juste après les étoiles de la note. Avec l'étoile comme icône de favori, les deux se confondent ; prévoir un écart ou une couleur distincte. À confirmer.
- L'état favori est-il envoyé à l'iPod, par exemple converti en note ? À confirmer.
- Sélection mixte (certains favoris, d'autres non) : le clic rend toute la sélection favorite.
- Emplacement de l'icône dans la vue Albums : non précisé. À confirmer.

---

## 3. Columns

### Objectifs

Laisser l'utilisateur choisir les colonnes qu'il veut voir, une seule fois, pour toutes les vues liste.

### Sous-tâches

- **MUS-4** : ouvrir un menu contextuel au clic droit sur la barre d'en-têtes de colonnes, avec une coche devant chaque colonne visible.
- **MUS-5** : appliquer le choix à toutes les vues liste et le conserver entre les sessions.

### Comportement utilisateur

- L'utilisateur fait un clic droit n'importe où dans la barre d'en-têtes.
- Un menu liste toutes les colonnes disponibles ; celles qui sont affichées portent une coche.
- Il choisit une colonne pour l'afficher ou la masquer ; la liste se met à jour aussitôt.

### Règles d'interaction

- Le clic droit fonctionne sur toute la largeur de la barre, y compris sur l'espace vide à droite de la dernière colonne.
- Chaque choix bascule une seule colonne ; le menu se ferme après le choix.
- Le réglage est global : masquer une colonne dans Songs la masque aussi dans Recently Added, dans les playlists et dans toute autre vue liste.
- Le réglage est enregistré et retrouvé au lancement suivant.

### États visuels

- **Menu** : une ligne par colonne, coche pour les colonnes visibles, pas de coche pour les masquées.
- **Colonne verrouillée** : ligne grisée et cochée, non cliquable.
- **Après bascule** : la colonne apparaît ou disparaît et les autres se réajustent sans saut de défilement.

### Edge cases

- La colonne du titre reste toujours visible, pour qu'une liste ne puisse jamais se retrouver sans colonne. À confirmer.
- Si la liste est triée sur une colonne qu'on masque, le tri retombe sur le tri par défaut de la vue.
- Une colonne qui n'a de sens que dans une vue (par exemple l'ordre dans une playlist) reste propre à cette vue et n'apparaît pas dans le menu des autres.
- L'ordre et la largeur des colonnes ne sont pas mentionnés dans le TODO ; hors périmètre de cette spec.

---

## 4. Sidebar Reorder

### Objectifs

Donner à l'utilisateur la main sur l'ordre de sa sidebar, avec le même geste et la même fluidité que dans le Finder.

### Sous-tâches

- **MUS-6** : réordonner un élément de la sidebar par clic maintenu puis glissement.
- **MUS-7** : limiter le déplacement au groupe d'origine (section principale ou playlists).
- **MUS-8** : animer le déplacement comme le Finder (les voisins s'écartent, l'élément se pose en douceur).
- **MUS-9** : conserver l'ordre entre les sessions.

### Comportement utilisateur

- L'utilisateur maintient le clic sur un élément, le fait glisser vers le haut ou le bas, puis relâche à l'endroit voulu.
- Pendant le glissement, les autres éléments s'écartent pour montrer où l'élément va se poser.
- Au relâchement, l'élément prend sa place et l'ordre est enregistré.

### Règles d'interaction

- Tous les éléments de la sidebar sont réordonnables.
- Un élément ne quitte jamais son groupe : un élément de la bibliothèque reste dans la bibliothèque, une playlist reste parmi les playlists.
- Un clic simple, sans glissement, sélectionne l'élément comme aujourd'hui.
- Relâcher hors d'une zone valide ou appuyer sur Échap annule le déplacement.
- Le réordonnancement ne change pas l'élément sélectionné ni le contenu affiché.

### États visuels

- **Glissement** : l'élément suit le pointeur, légèrement translucide.
- **Cible valide** : un espace s'ouvre entre deux éléments à l'emplacement de dépôt.
- **Cible invalide** : aucun espace ne s'ouvre hors du groupe d'origine ; l'élément revient à sa place au relâchement.
- **Dépôt** : l'élément glisse jusqu'à sa position finale, les voisins se referment.

### Edge cases

- Les en-têtes de groupe (iPods, Library, Playlists) ne sont pas déplaçables. À confirmer.
- Les éléments du groupe iPods dépendent des appareils branchés ; leur réordonnancement est-il utile ? À confirmer.
- Glisser une playlist sur un dossier de playlists la range-t-il dans le dossier, ou le geste reste-t-il un simple réordonnancement ? À confirmer, en lien avec MUS-19.
- Ce geste ne doit pas entrer en conflit avec le dépôt de morceaux ou d'albums sur une playlist : glisser un élément de sidebar réordonne, glisser du contenu ajoute.
- Liste longue : la sidebar défile automatiquement quand le pointeur approche du bord haut ou bas.
- Un élément ajouté plus tard (nouvelle playlist, nouvelle section) se place à la fin de son groupe.

---

## 5. Albums View

### Objectifs

Faire de la grille d'albums une vue agréable à manipuler : un glisser élégant vers l'iPod ou une playlist, un détail d'album qui met les morceaux en avant, une sélection multiple et une lecture rapide au survol.

### Sous-tâches

- **MUS-10** : habiller le glisser d'album (fondu du titre, de l'artiste et du rectangle de sélection, réduction d'échelle, albums glissés translucides).
- **MUS-11** : au clic sur un album, faire défiler la vue pour aligner le haut de la pochette sur le haut de la zone visible.
- **MUS-12** : afficher la pochette en grand, floutée ou en filigrane, derrière la liste des morceaux de l'album ouvert.
- **MUS-13** : afficher le nom de l'album, l'artiste et l'année dans le détail de l'album.
- **MUS-14** : sélectionner plusieurs albums par ⌘-clic, rectangle de sélection ou ⌘A.
- **MUS-15** : afficher au survol d'un album un bouton de lecture (SF Symbol play.circle.fill) qui apparaît en fondu.

### Comportement utilisateur

- **Glisser** : l'utilisateur attrape un album ; le texte et le cadre de sélection s'effacent, la pochette rétrécit et suit le pointeur jusqu'à l'iPod ou une playlist.
- **Ouvrir** : il clique un album ; la vue défile d'elle-même et la liste des morceaux s'affiche sur un fond tiré de la pochette, avec l'album, l'artiste et l'année.
- **Sélectionner** : il ajoute des albums à la sélection par ⌘-clic, trace un rectangle dans le vide de la grille, ou appuie sur ⌘A pour tout prendre.
- **Lire** : il survole un album, un bouton de lecture apparaît ; un clic lance l'album.

### Règles d'interaction

- Glisser un album sélectionné emporte toute la sélection ; glisser un album non sélectionné n'emporte que celui-là.
- Les cibles de dépôt sont l'iPod et les playlists de la sidebar.
- Le défilement automatique de MUS-11 est animé et vise à montrer le plus de morceaux possible sous la pochette.
- ⌘-clic ajoute ou retire un album de la sélection sans ouvrir son détail.
- Le rectangle de sélection démarre dans un espace vide de la grille ; ⌘ maintenu, il s'ajoute à la sélection existante.
- ⌘A sélectionne tous les albums de la vue courante, filtre de recherche compris.
- Le bouton de lecture lance l'album depuis le premier morceau, sans ouvrir le détail ni modifier la sélection.

### États visuels

- **Repos** : pochette, titre et artiste.
- **Survol** : bouton de lecture en fondu sur la pochette.
- **Sélectionné** : rectangle de sélection autour de l'album.
- **Glissement** : titre, artiste et rectangle disparus ; pochette réduite et translucide sous le pointeur ; avec plusieurs albums, pochettes empilées.
- **Album ouvert** : liste des morceaux sur fond de pochette agrandie et floutée, suffisamment atténuée pour que le texte reste lisible en thème clair comme en thème sombre.
- **Sans pochette** : fond neutre standard pour la liste, pochette de remplacement dans la grille.

### Edge cases

- Année absente : la ligne n'affiche que l'album et l'artiste, sans séparateur orphelin.
- Années différentes selon les morceaux d'un même album : afficher la plus ancienne. À confirmer.
- Album dans la dernière rangée : s'il n'y a pas assez de contenu pour aligner la pochette en haut, défiler au maximum possible.
- Album déjà ouvert puis recliqué : le détail se referme, sans défilement.
- Clic simple sur un album alors qu'une sélection multiple existe : la sélection se réduit à cet album et son détail s'ouvre.
- Bouton de lecture pendant un glissement ou un tracé de rectangle : masqué.
- Album en cours de lecture : le bouton au survol devient-il un bouton pause ? À confirmer.
- Sélection de plusieurs centaines d'albums : l'aperçu de glissement montre quelques pochettes et un compteur, pas toutes les pochettes.
- Les mêmes gestes de sélection et de glisser s'appliquent-ils à la grille Artists ? Hors périmètre ici, à décider avec la refonte Artists.

---

## 6. Playlists

### Objectifs

Rendre la création de contenu accessible depuis la sidebar, et afficher les playlists dans le même format liste que le reste de la bibliothèque.

### Sous-tâches

- **MUS-16** : afficher un bouton + en fondu à côté du titre du groupe Playlists, qui ouvre un menu.
- **MUS-17** : entrée de menu « Add New Music local folder ».
- **MUS-18** : entrée de menu « New Playlist ».
- **MUS-19** : entrée de menu « New Playlist Folder ».
- **MUS-20** : afficher le contenu d'une playlist en vue liste.

### Comportement utilisateur

- L'utilisateur survole le titre du groupe Playlists ; un bouton + apparaît en fondu.
- Il clique le + et choisit l'une des trois entrées.
- **Add New Music local folder** : un sélecteur de dossier s'ouvre ; le dossier choisi est ajouté aux dossiers de la bibliothèque et son contenu est importé.
- **New Playlist** : une playlist vide apparaît dans la sidebar, son nom déjà en édition.
- **New Playlist Folder** : un dossier vide apparaît dans la sidebar, son nom déjà en édition.
- Il ouvre une playlist et voit ses morceaux en vue liste, dans l'ordre de la playlist.

### Règles d'interaction

- Le + n'est visible qu'au survol du titre du groupe ou quand le menu est ouvert.
- Entrée valide le nom ; Échap garde le nom par défaut.
- Un nouvel élément se place à la fin du groupe Playlists et peut ensuite être déplacé (section 4).
- La vue liste d'une playlist suit le réglage global des colonnes (section 3) et garde par défaut l'ordre de la playlist.
- Glisser des morceaux dans la liste d'une playlist change leur ordre, tant que la liste est triée dans l'ordre de la playlist.

### États visuels

- **Titre du groupe au repos** : pas de bouton.
- **Titre survolé** : bouton + en fondu.
- **Menu ouvert** : trois entrées, le + reste visible.
- **Nouvel élément** : ligne de sidebar avec champ de nom en édition et texte sélectionné.
- **Playlist vide** : message court invitant à y glisser des morceaux.

### Edge cases

- L'actuelle ligne « New Playlist… » de la sidebar est-elle retirée au profit du +, ou conservée ? À confirmer.
- « Add New Music local folder » dans le menu du groupe Playlists ajoute de la musique à la bibliothèque, pas une playlist : emplacement voulu par le TODO, à confirmer.
- Dossier déjà présent dans la bibliothèque, ou sous-dossier d'un dossier déjà suivi : ne pas dupliquer, informer l'utilisateur.
- Dossier sans fichier audio lisible : l'ajouter quand même ou le refuser avec un message ? À confirmer.
- Nom déjà utilisé : ajouter un numéro au nom par défaut (« New Playlist 2 »).
- Les dossiers de playlists peuvent-ils être imbriqués, et comment apparaissent-ils sur l'iPod ? À confirmer.
- Utilisateur au clavier ou sur écran tactile, sans survol : le + doit rester atteignable (focus clavier, menu contextuel du titre).
- Liste de playlist triée sur une autre colonne : le réordonnancement manuel est désactivé jusqu'au retour à l'ordre de la playlist.

---

## 7. Metadata Editor (fenêtre externe)

### Objectifs

Offrir un éditeur de métadonnées complet et familier, calqué sur la fenêtre d'informations d'iTunes, dans une fenêtre séparée de la fenêtre principale.

### Sous-tâches

- **MUS-21** : ouvrir le Metadata Editor dans une fenêtre externe, distincte de la fenêtre principale.
- **MUS-22** : afficher un en-tête avec la pochette, le titre, l'artiste et l'album du morceau.
- **MUS-23** : organiser l'éditeur en six onglets : Details, Artwork, Lyrics, Options, Sorting, File.
- **MUS-24** : construire l'onglet Details avec les champs de la référence iTunes.
- **MUS-25** : ajouter les boutons précédent et suivant pour passer d'un morceau à l'autre sans fermer la fenêtre.
- **MUS-26** : ajouter les boutons Cancel et OK.
- **MUS-27** : construire l'onglet Artwork (pochette en grand et bouton Add Artwork).
- **MUS-28** : construire l'onglet Lyrics (zone de texte et case Custom Lyrics).
- **MUS-29** : construire l'onglet Options (type de média, début et fin, lecture, volume, égaliseur).
- **MUS-30** : construire l'onglet Sorting (valeur de tri pour chaque champ de nom).
- **MUS-31** : construire l'onglet File (informations techniques en lecture seule).
- **MUS-32** : rendre l'en-tête translucide, le haut de la fenêtre laissant deviner ce qui se trouve derrière.

### Comportement utilisateur

- L'utilisateur ouvre l'éditeur depuis un morceau ; une fenêtre séparée apparaît, la fenêtre principale reste visible derrière.
- L'en-tête rappelle le morceau édité : pochette à gauche, titre en grand, artiste et album en dessous.
- Il change d'onglet pour accéder aux différents types d'informations ; l'en-tête, les flèches et les boutons Cancel et OK restent en place d'un onglet à l'autre.
- Dans Details, il modifie les champs, puis valide avec OK ou abandonne avec Cancel.
- Dans Artwork, il voit la pochette en grand et en ajoute une avec Add Artwork.
- Dans Lyrics, il coche Custom Lyrics puis saisit ou colle les paroles.
- Dans Options, il règle la façon dont le morceau est lu.
- Dans Sorting, il indique sous quel nom classer le morceau, l'album ou l'artiste.
- Dans File, il consulte les caractéristiques du fichier et son emplacement.
- Avec les flèches en bas à gauche, il passe au morceau précédent ou suivant de la liste d'origine, en restant sur le même onglet.

### Champs de l'onglet Details (MUS-24)

| Champ | Type |
| --- | --- |
| song | texte |
| artist | texte |
| album | texte |
| album artist | texte |
| composer | texte, avec la case « Show composer in all views » |
| grouping | texte |
| genre | texte avec liste de suggestions |
| year | nombre |
| track | numéro et total (« 3 of 12 ») |
| disc number | numéro et total |
| compilation | case « Album is a compilation of songs by various artists » |
| rating | cinq étoiles, suivies de l'icône des favoris |
| bpm | nombre |
| play count | lecture seule, avec la date de dernière lecture et un bouton Reset |
| comments | texte |

Le libellé « song » porte un sélecteur, comme dans la référence ; son rôle n'est pas précisé. À confirmer.

### Onglet Artwork (MUS-27)

- Titre « Album Artwork » au-dessus de la pochette, affichée en grand sur toute la largeur de l'onglet.
- Bouton Add Artwork dans la barre du bas, entre les flèches et Cancel ; il ouvre un sélecteur d'image.
- La vignette de l'en-tête se met à jour dès qu'une pochette est ajoutée.

### Onglet Lyrics (MUS-28)

- Grande zone de texte défilante occupant tout l'onglet.
- Case Custom Lyrics dans la barre du bas, entre les flèches et Cancel. Cochée, la zone est modifiable et son contenu est enregistré avec le morceau.

### Onglet Options (MUS-29)

| Champ | Type |
| --- | --- |
| media kind | menu (Music par défaut) |
| start | case à cocher et temps (0:00 par défaut) |
| stop | case à cocher et temps (durée du morceau par défaut, au millième) |
| playback | cases « Remember playback position » et « Skip when shuffling » |
| volume adjust | curseur de −100 % à +100 %, « None » au centre |
| equalizer | menu (None par défaut) |

### Onglet Sorting (MUS-30)

Cinq paires de champs, chaque champ de nom suivi de son champ « sort as » :

| Champ | Champ de tri |
| --- | --- |
| name | sort as |
| album | sort as |
| album artist | sort as |
| artist | sort as |
| composer | sort as |

- Les champs de nom sont les mêmes que dans Details ; une modification ici s'y reflète.
- Un champ « sort as » laissé vide affiche en grisé la valeur du champ de nom, qui sert alors de valeur de tri.

### Onglet File (MUS-31)

Tout est en lecture seule.

| Champ | Exemple |
| --- | --- |
| kind | MPEG audio file |
| duration | 4:26 |
| size | 10.4 MB |
| bit rate | 320 kbps |
| sample rate | 44.100 kHz |
| channels | Stereo |
| volume | vide si aucune valeur |
| id3 tag | v2.4 |
| encoded with | Lavf59.9.102 |
| format | MPEG-1, Layer 3 |
| date modified | date et heure |
| date added | date et heure |
| location | chemin complet du fichier, sur plusieurs lignes si nécessaire |

### Règles d'interaction

- OK enregistre toutes les modifications et ferme la fenêtre ; Entrée équivaut à OK.
- Cancel ferme la fenêtre sans rien enregistrer ; Échap équivaut à Cancel.
- Les flèches précédent et suivant suivent l'ordre de la liste d'où l'éditeur a été ouvert.
- L'en-tête reflète en direct le contenu des champs song, artist et album.
- Tab passe d'un champ au suivant dans l'ordre visuel.
- Les champs year, track, disc number et bpm n'acceptent que des chiffres.
- Reset remet le compteur de lecture à zéro, après validation par OK.
- OK et Cancel portent sur l'ensemble des onglets, pas seulement sur l'onglet affiché.
- Dans Options, les champs start et stop ne s'appliquent que si leur case est cochée.
- Dans Lyrics, la zone de texte n'est modifiable que si Custom Lyrics est cochée.
- Les contrôles propres à un onglet (Add Artwork, Custom Lyrics) n'apparaissent dans la barre du bas que sur cet onglet.
- L'écriture des tags dans les fichiers se fait hors du thread principal ; la fenêtre reste réactive.

### États visuels

- **En-tête** : bandeau translucide en haut de la fenêtre, plus clair que le corps ; le fond derrière la fenêtre s'y devine, flouté. Le corps de la fenêtre reste opaque.
- **Titre trop long** : tronqué par des points de suspension dans l'en-tête ; le champ song affiche le titre complet.
- **Onglet actif** : mis en évidence par la couleur d'accent, les autres neutres.
- **Champ vide** : champ sans texte, sans valeur de remplacement, sauf les champs « sort as » (valeur grisée).
- **Sans pochette** : image de remplacement dans l'en-tête et dans l'onglet Artwork.
- **Flèche inactive** : grisée au premier et au dernier morceau de la liste.
- **Favori** : icône pleine à côté des étoiles, en contour sinon ; cœur ou étoile selon le réglage (MUS-3).
- **Lecture seule** : dans File, valeurs en texte simple, sans cadre de champ.
- **Enregistrement en cours** : bouton OK inactif jusqu'à la fin de l'écriture.

### Edge cases

- Passer au morceau suivant avec des modifications non enregistrées : les enregistrer d'office, comme iTunes, ou demander ? À confirmer.
- Fermeture par le bouton de fenêtre : traitée comme Cancel. À confirmer.
- Édition de plusieurs morceaux à la fois : les champs aux valeurs différentes affichent une mention « Mixed » et seuls les champs modifiés sont écrits. Non mentionné dans le TODO, à confirmer.
- Fichier introuvable ou en lecture seule : champs désactivés et message expliquant pourquoi.
- Échec d'écriture des tags : la fenêtre reste ouverte, le message d'erreur indique le fichier concerné, les saisies sont conservées.
- Morceau présent seulement sur l'iPod : éditable ou non ? À confirmer.
- Morceau supprimé de la bibliothèque pendant que l'éditeur est ouvert : la fenêtre se ferme ou passe au morceau suivant.
- Une seule fenêtre d'éditeur à la fois, ou une par morceau ? À confirmer.
- En-tête translucide sur Windows et Linux : utiliser l'effet de flou natif de chaque système ; s'il n'est pas disponible, ou si l'utilisateur a réduit la transparence, afficher un bandeau opaque de la même teinte.
- Artwork : image très lourde ou dans un format non géré, glisser-déposer d'une image sur la pochette, suppression ou remplacement d'une pochette existante. À confirmer.
- Artwork : la pochette ajoutée s'applique-t-elle au seul morceau ou à tout l'album ? À confirmer.
- Lyrics : décocher Custom Lyrics alors que du texte est saisi efface-t-il les paroles ou les masque-t-il ? À confirmer. Le lien avec la recherche de paroles par plug-in reste à définir.
- Options : stop antérieur à start, ou au-delà de la durée du morceau : valeur refusée et ramenée à la limite.
- Options : media kind changé pour autre chose que Music : le morceau quitte la section Musique après OK.
- Options : quels réglages l'iPod respecte-t-il (début et fin, volume, égaliseur, saut en lecture aléatoire) ? Ceux qui ne sont pas pris en charge sont à masquer plutôt qu'à afficher sans effet. À confirmer.
- File : les champs propres à un format (id3 tag) sont masqués quand ils ne s'appliquent pas. Un moyen d'afficher le fichier dans le Finder ou l'explorateur serait utile. À confirmer.

---

## Hors périmètre

- **Refonte de la section Artists** : le TODO demande un design plus soigné, avec un travail sur l'arrière-plan, en partant de la capture d'écran actuelle. Ce chantier n'est pas dans la liste des sections de cette spec et reste à cadrer séparément.

## Questions ouvertes

1. Favorites : avec l'étoile comme icône, comment la distinguer des étoiles de la note ?
2. Favorites : l'état favori doit-il être synchronisé vers l'iPod ?
3. Recently Added : quelle définition de « récent » (durée ou nombre de morceaux) ?
4. Sidebar Reorder : le groupe iPods et les en-têtes de groupe sont-ils concernés ?
5. Sidebar Reorder : glisser une playlist sur un dossier la range-t-il dedans ?
6. Playlists : la ligne « New Playlist… » existante disparaît-elle ?
7. Playlists : « Add New Music local folder » a-t-il bien sa place dans le menu du groupe Playlists ?
8. Metadata Editor : édition multiple, enregistrement au changement de morceau, et nombre de fenêtres ouvertes en même temps.
