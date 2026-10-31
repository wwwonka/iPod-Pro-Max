# Sidebar translucide sous Linux

Comme la sidebar du Mac (`NSVisualEffectView`) et l'acrylique de Windows : la sidebar laisse deviner le bureau, le reste de la fenêtre reste opaque et net.

**Règle** : rien à installer, aucune permission à demander, pas de déconnexion. D'où trois modes, choisis tout seuls par `GlassGtk.swift` :

| Mode | Quand | Ce qu'on voit |
|---|---|---|
| **Verre** | le compositeur floute déjà derrière les fenêtres : Hyprland, ou Blur my Shell que l'utilisateur a déjà (flou « Applications », app dans sa liste blanche) | le bureau et les fenêtres derrière, floutés en direct |
| **Teinte du fond d'écran** | GNOME sans flou (le cas par défaut) | un dégradé doux tiré du fond d'écran, comme la teinte des fenêtres de macOS |
| **Opaque** | les autres bureaux | la couleur de sidebar du Mac |

`IPPM_GLASS=1`, `tint` ou `0` force un mode, pour essayer.

## Pourquoi pas un vrai flou partout sous GNOME
GNOME Shell ne propose aucune API de flou aux apps : flouter ce qui est derrière une fenêtre demande du code dans le Shell, c'est-à-dire une extension, à installer et qui n'est chargée qu'à la prochaine ouverture de session. Refusé : l'app ne doit rien installer ni rien demander. Une app ne peut pas non plus le faire elle-même : sous Wayland, elle ne voit pas le bureau et ne connaît pas sa position.

(WhiteSur-Glassy et Aura Glass reposent tous deux sur l'extension Blur my Shell, plus un thème GTK qui rend les fonds transparents.)

## La teinte du fond d'écran (`WallpaperTintGtk.swift`)
- Le fond d'écran vient des réglages de GNOME (`org.gnome.desktop.background`, variantes claire et sombre), sans permission. Diaporamas XML : la première image. SVG et JPEG XL (fonds par défaut de GNOME 50) sont décodés par GTK/glycin.
- Rendu en petit (96 px de large, sans jamais décoder l'image en grand), flouté très fort (trois flous en boîte), mélangé à 65 % avec la couleur de sidebar du Mac, enregistré en PNG dans `~/.cache/iPodProMax/`. GTK l'étire en douceur : ce ne sont que des dégradés, donc la position de la fenêtre n'a pas d'importance.
- **Coût** : quelques millisecondes hors du thread principal, une fois au lancement et à chaque changement de fond d'écran (signal GSettings, pas de polling). Les versions claire et sombre sont prêtes d'avance : changer d'apparence ne coûte rien.
- Si le fond d'écran ne peut pas être lu, la couleur unie des réglages de GNOME sert de teinte ; sinon, la sidebar reste opaque.

Vérifié dans la VM Fedora 44 (GNOME 50.6, Wayland) : teinte au lancement (fond SVG), puis changement de fond d'écran en direct vers un JPEG XL, suivi sans relancer l'app (captures).

## Le mode verre (`GlassGtk.swift`)
Seule la sidebar devient translucide (fond de fenêtre transparent, couleurs du Mac à 60 %), le compositeur floute sur le GPU, l'app ne calcule rien. Il suit les réglages de Blur my Shell en direct. Avec Blur my Shell, mettre l'**opacité des applications à 255** : à 215 (défaut), toute la fenêtre est estompée, texte compris.

## Plus tard
- **KDE** : KWin floute à la demande de l'app (protocole Wayland `org_kde_kwin_blur`), sans extension ni permission : le vrai mode verre, natif. Carte à part ; à tester dans une session KDE.
- **`ext-background-effect-v1`** : protocole Wayland standard de flou d'arrière-plan. Si GNOME l'expose un jour, l'app pourra demander le vrai flou elle-même.

Voir [[Composants natifs par plateforme]].
