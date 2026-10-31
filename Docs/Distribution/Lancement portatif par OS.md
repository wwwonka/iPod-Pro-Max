# Lancement portatif par OS

## Le lanceur « shadow copy » (les trois OS)
L'app **ne s'exécute jamais directement depuis l'iPod**. Un seul fichier, `Distribution/Launcher/LAUNCHER.cmd`, sert les trois OS : c'est à la fois un script POSIX sh et un batch Windows (technique de github.com/ChewKeanHo/research-the-polyglot-scripts). `cmd` prend les lignes commençant par `:` pour des étiquettes, et le bloc batch est caché à `sh` dans un heredoc (`:<<"::WINDOWS"`). Le fichier garde des fins de ligne LF : le batch n'utilise donc ni étiquette ni `goto`, que `cmd` retrouve mal dans ce cas. Il est posé à la racine de l'iPod sous `LAUNCHER.cmd` (Windows, et `sh LAUNCHER.cmd` sous Linux) et `LAUNCHER.command` (double-clic sur macOS). Le nom est provisoire. Il :
1. trouve la racine de l'iPod (son propre dossier), l'OS et l'architecture ;
2. compare `iPod Pro Max/version.txt` à celui de la copie locale (`~/Library/Caches/iPod Pro Max/App`, `%LOCALAPPDATA%\iPod Pro Max\App-<arch>`, `~/.cache/ipod-pro-max/App`) ;
3. recopie l'app de cet OS et de cette architecture si la version a changé ;
4. lance la copie locale avec `--portable-root <racine de l'iPod>` ; l'app y lit et écrit `iPod Pro Max/Persistent Data/`, partagé par les 3 OS.

`LAUNCHER cli <arguments>` fait de même pour la CLI (copie dans `…/Command Line`) et lui passe `IPPM_PORTABLE_ROOT`, pour qu'elle voie l'iPod même quand c'est `Build/` (non monté).

Limite actuelle : une fenêtre Terminal (macOS) ou une console (Windows) s'ouvre au lancement. Des micro-lanceurs silencieux viendront ensuite.

## Versions minimales
| OS | Minimum | Ce qui l'impose |
|---|---|---|
| macOS | 10.15.4 (x86_64), 11 (Apple Silicon) | SwiftCrossUI (10.15), `FileHandle` d'iPodKit (10.15.4). Sous macOS 10.15, pas de SF Symbols : l'app s'affiche sans ces icônes. Sous 12 (ou 15 pour l'audio), MediaKit passe par ffmpeg et le lecteur de tags portable au lieu d'AVFoundation. Le runtime de concurrence Swift est livré dans l'app. |
| Windows | 10 (1809) | runtime Swift et WinUI 3 |
| Linux (app) | glibc 2.35 et GTK 4.6 (Ubuntu 22.04, Debian 12 et plus récents) | compilée sur Ubuntu 22.04 |
| Linux (CLI) | n'importe quel noyau x86_64 ou aarch64 | entièrement statique (musl) |

Plus ancien (Yosemite, Windows XP/7) n'est pas atteignable avec Swift, SwiftCrossUI et WinUI : il faudrait une autre application. Les sorties macOS 10.15 et Windows 10 x64 ne sont pas encore vérifiées sur une vraie machine.

Ce que ça règle :
- **Éjection** : aucun binaire n'est ouvert sur l'iPod, donc l'OS accepte de l'éjecter (Windows et macOS refusent sinon).
- **Vitesse** : on démarre depuis le SSD, pas depuis le disque dur lent de l'iPod.
- **Linux** : `noexec` et `showexec` sur le FAT32 ne gênent plus.
- **macOS** : plus de translocation (voir plus bas).

## macOS
- `.app` universel (arm64 + x86_64), **signé ad hoc** (pas de certificat payant).
- **Piège :** un zip téléchargé depuis GitHub porte l'attribut de quarantaine. Copié sur FAT32, cet attribut survit dans les fichiers `._`. Sur un autre Mac, ça déclenche Gatekeeper et l'**App Translocation**, qui exécute l'app depuis un chemin aléatoire en lecture seule.
- **Réponse :**
  - le lanceur copie l'app en local et retire `com.apple.quarantine` de la copie (`xattr -dr`) ;
  - l'app trouve l'iPod par le volume monté, jamais par le chemin de son bundle ;
  - au tout premier lancement sur un Mac, l'utilisateur passe par Réglages › Confidentialité › « Ouvrir quand même ». C'est documenté dans un `LISEZMOI` à la racine du dossier.
- Les autorisations TCC (dossier Musique, volumes amovibles) sont redemandées après chaque mise à jour, parce que la signature ad hoc change.

## Windows
- `iPodProMaxApp.exe` (WinUI), DLL du runtime Swift et du Windows App SDK à côté. Le Windows App Runtime doit encore être présent sur l'hôte : le déploiement autonome (« self-contained ») reste à faire pour n'avoir rien à installer.
- Pas de Mark-of-the-Web sur FAT32 (pas de flux NTFS alternatif), donc SmartScreen est peu probable une fois l'app sur l'iPod.
- Copie locale dans `%LOCALAPPDATA%\iPod Pro Max\App-<arch>`.

## Linux
- Binaire avec la stdlib Swift statique. glibc et GTK4 sont liés dynamiquement. Compilé dans Docker sur Ubuntu 22.04, pour x86_64 et aarch64 (`Tools/Build/build-linux-docker.sh`), afin de couvrir les distributions plus récentes.
- udisks2 monte le vfat avec `showexec` : seuls `.exe`, `.com` et `.bat` sont exécutables. On lance donc par `sh LAUNCHER.cmd`, qui copie l'app en local et lui rend ses droits d'exécution.
- Copie locale dans `~/.cache/ipod-pro-max/App`.

## FAT32
Le mode portatif exige un iPod formaté Windows (FAT32). Voir [[ADR-005 FAT32 en mode portatif]].

Voir aussi [[CI et packaging]] et [[Risques]].
