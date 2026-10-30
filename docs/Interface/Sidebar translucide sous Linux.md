# Sidebar translucide sous Linux

Comme la sidebar du Mac (`NSVisualEffectView`) et l'acrylique de Windows : on voit le bureau flouté à travers la sidebar, le reste de la fenêtre reste opaque.

## Comment font WhiteSur-Glassy et Aura Glass
Ni l'un ni l'autre ne floute dans l'app :
- un **thème GTK/libadwaita** rend les fonds des fenêtres transparents (`rgba`), en gardant texte et contrôles opaques ;
- l'extension GNOME **Blur my Shell** floute ce qu'il y a derrière les fenêtres, dans le compositeur (GNOME Shell), sur le GPU.

## Ce que fait le prototype (`GlassGtk.swift`)
Le même principe, mais sans thème à installer : seule la sidebar de notre fenêtre devient translucide (fond de la fenêtre transparent, sidebar aux couleurs du Mac à 60 %, colonne de droite opaque).
- **Aucun coût pour l'app** : pas de flou calculé par nous (sous Wayland une app ne voit même pas le bureau) ; le compositeur mélange et floute sur le GPU.
- **Seulement quand ça floute vraiment** : une sidebar transparente sans flou laisse voir le bureau net derrière le texte. Le mode s'active donc si :
  - GNOME, Blur my Shell activée, son flou « Applications » allumé, et `com.ipodpromax.proto` dans sa liste blanche (ou « flouter toutes les applications ») ;
  - Hyprland, qui floute par défaut les fenêtres translucides.
- **Réagit en direct**, par signal GSettings (pas de polling) : activer ou couper le flou dans Blur my Shell change la sidebar sans relancer l'app.
- `IPPM_GLASS=1` ou `0` force le mode, pour essayer.

## Réglages conseillés dans Blur my Shell
Applications : flou activé, `com.ipodpromax.proto` dans la liste blanche, **opacité 255**. L'opacité par défaut (215) estompe la fenêtre entière, texte compris ; à 255, seule la sidebar est translucide et tout le reste reste net.

Vérifié dans la VM Fedora 44 (GNOME 50.6, Wayland) : transparence forcée (capture), puis détection et bascule en direct quand le flou est activé dans les réglages de Blur my Shell. Le flou lui-même ne s'est pas vu dans la VM : une extension installée n'est chargée qu'à la prochaine ouverture de session.

## Plus tard
- **KDE** : KWin floute à la demande de l'app (protocole `org_kde_kwin_blur`), sans extension. Carte à part.
- **`ext-background-effect-v1`** : protocole Wayland standard de flou d'arrière-plan. GNOME 50 ne l'expose pas encore ; s'il arrive, le prototype pourra demander le flou lui-même, sans Blur my Shell.

Voir [[Composants natifs par plateforme]].
