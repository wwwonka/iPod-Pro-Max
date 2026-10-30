# CI et packaging

## GitHub Actions
| Job | Runner | Produit |
|---|---|---|
| `test-linux` | `ubuntu` + Swift 6.x | Tests d'iPodKit, dont les **tests de référence** : le DB écrit sur Linux doit être identique octet pour octet à celui du Mac |
| `build-macos` | `macos` | `.app` universel signé ad hoc |
| `build-windows` | `windows` + Swift 6.x + MSYS2 (GTK4) | `.exe` + DLL |
| `build-linux` | conteneur d'une vieille distro + Swift 6.x | Binaire, `lancer.sh`, `.desktop` |
| `assemble` | `ubuntu` | `iPod-Pro-Max-portable.zip` qui contient le dossier `iPod Pro Max/` complet (voir [[Sur l'iPod]]) |

## Tests de référence (phase 1)
On part de `Tools/dbtest`. On génère sur Mac un jeu de bibliothèques de test, puis les DB attendus : iTunesDB, ArtworkDB, Photo Database et signature hash58 avec un FireWire GUID fixe. On les met dans le repo, et chaque OS doit produire exactement les mêmes octets. C'est la garantie qu'une sync depuis Windows ou Linux ne corrompt pas l'iPod.

## Outils embarqués
- **ffmpeg** : builds statiques par OS. **Licence** : une build avec libx264 est sous GPL, et la redistribuer impose de fournir les sources ou une offre écrite. Choix à faire entre une build LGPL (sans x264, mais avec les encodeurs matériels) et la GPL assumée avec un `LICENSES/` dans le dossier. Voir [[Risques]].
- **yt-dlp** : binaires autonomes officiels par OS (`yt-dlp_macos`, `yt-dlp.exe`, `yt-dlp_linux`). Mise à jour automatique (`-U`) au lancement, en arrière-plan, au plus une fois par jour, parce que YouTube casse yt-dlp régulièrement.

## Installation sur l'iPod
L'app elle-même propose « Mettre à jour l'app sur cet iPod ». Elle télécharge la dernière release et remplace `App/` et `Tools/` de façon atomique (dossier temporaire puis renommage).

Voir [[Lancement portatif par OS]] et [[Compilation multiplateforme]].

## État (2026-10-30)
Les tests de référence existent (`Tests/iPodKitTests/ReferenceTests.swift`) : empreintes de l'iTunesDB, de la signature hash58 et des vignettes, identiques sur macOS, Linux et Windows. Pas encore de GitHub Actions : les trois OS sont testés dans les VM Parallels. Voir [[Package Swift]].
