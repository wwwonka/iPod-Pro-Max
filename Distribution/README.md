# Distribution

Ce qui va sur l'iPod en plus des applications. `Tools/Build/assemble-ipod.sh` (appelé par `Tools/Build/build.sh` et `Build.command`) en fait la racine d'un iPod dans `Build/`.

| Dossier | Rôle |
|---|---|
| `iPod Root/` | Assets copiés tels quels à la racine de l'iPod (`Build/`). Y mettre ce qui doit simplement se retrouver sur l'iPod. Un `iPod_Control/` mis ici sert de modèle à la place de l'iPod simulé généré, s'il n'existe pas encore dans `Build/`. |
| `Launcher/LAUNCHER.bat` | Le lanceur polyglotte (sh + cmd), copié à la racine sous `LAUNCHER.bat`. |

Disposition produite : `Docs/Données/Sur l'iPod.md`.
