# Plug-in yt-dlp : vérifications préalables (`YTD-1`)

Mesures effectuées le 2026-11-16 avec `yt-dlp 2026.10.26`, `deno 2.9.8` et le binaire `ffmpeg 8.1` produit par [`Tools/FFmpeg/build.sh`](../../Tools/FFmpeg/build.sh).

## 1. Nécessité d'un runtime JavaScript externe (Deno)

### Constat empirique

Testé sur une piste YouTube Music réelle (`https://music.youtube.com/watch?v=fsGjRf-N71I`) :

- **Sans runtime JavaScript (`--no-js-runtimes`)** :
  `yt-dlp 2026.10.26` émet explicitement :
  `WARNING: [youtube] No supported JavaScript runtime could be found. Only deno is enabled by default... YouTube extraction without a JS runtime has been deprecated, and some formats may be missing.`
  L'extracteur se replie uniquement sur le client `visionos` (le client `tv samsung` et la résolution complète `web`/EJS sont ignorés, et les streams sans contournement EJS risquent des formats manquants ou des `HTTP Error 403` selon la vidéo).
- **Avec Deno (`--js-runtimes deno:<chemin>`)** :
  `yt-dlp 2026.10.26` résout les défis JS sans avertissement (`[youtube] [jsc:deno] Solving JS challenges using deno`) avec les composants `yt-dlp-ejs` déjà embarqués dans les binaires officiels (aucune option `--remote-components` requise au runtime).
- **Recherches (`--dump-json --flat-playlist`)** :
  Les recherches `music.youtube.com/search?q=…` et `ytsearch5:"…"` fonctionnent sans résoudre les défis JS des vidéos individuelles ; Deno n'est sollicité qu'au moment de l'extraction / du téléchargement d'une vidéo.

### Impact sur la taille par OS (`yt-dlp 2026.10.26` + `deno 2.9.8`)

| Plateforme / architecture | `yt-dlp` officiel | Archive ZIP `deno 2.9.8` | Binaire `deno` décompressé (mesuré) |
| --- | --- | --- | --- |
| macOS universal (`macos`) | `yt-dlp_macos` : 35,73 Mio | — | — |
| macOS arm64 | (inclus dans `yt-dlp_macos`) | `deno-aarch64-apple-darwin.zip` : 36,97 Mio | ~125 Mio (`/opt/homebrew/.../deno`) |
| macOS x86_64 | (inclus dans `yt-dlp_macos`) | `deno-x86_64-apple-darwin.zip` : 40,81 Mio | ~125 Mio |
| Windows x64 | `yt-dlp.exe` : 22,48 Mio | `deno-x86_64-pc-windows-msvc.zip` : 40,93 Mio | ~120 Mio |
| Windows arm64 | (émulation `yt-dlp.exe`) | `deno-aarch64-pc-windows-msvc.zip` : 39,26 Mio | ~115 Mio |
| Linux x86_64 | `yt-dlp_linux` : 39,26 Mio | `deno-x86_64-unknown-linux-gnu.zip` : 40,02 Mio | ~120 Mio |
| Linux aarch64 | `yt-dlp_linux_aarch64` : 38,90 Mio | `deno-aarch64-unknown-linux-gnu.zip` : 38,26 Mio | ~115 Mio |

**Décision** : embarquer `yt-dlp` **et** `deno` dans `Plug-ins/yt-dlp/vendor/` via `Tools/Build/fetch-ytdlp-vendor.sh` (téléchargement à version figée + vérification SHA256), et passer `--js-runtimes deno:<chemin>` lorsque `deno` est présent (avec repli gracieux si absent).

---

## 2. Capacités du `ffmpeg` minimal (`Tools/FFmpeg/build.sh`)

Le script `Tools/FFmpeg/build.sh` inclut déjà :
- **Démuxeurs** : `mov` (pour `.m4a` / `.mp4`) et `matroska` (qui couvre `.mkv` **et `.webm`** dans FFmpeg) ;
- **Décodeurs** : `aac`, `opus` ;
- **Encodeur** : `aac` (plus `aac_at` sur macOS / `aac_mf` sur Windows) ;
- **Muxeurs** : `mp4`, `ipod`, `mov`.

### Vérification empirique sur le binaire `.build-work/FFmpeg/macos-arm64/ffmpeg` (5,1 Mo)

Testé sur deux flux réels récupérés sur YouTube (`https://www.youtube.com/watch?v=jNQXAC9IVRw`) :
1. **Remuxage `.m4a` sans réencodage** (`ffmpeg -i in.m4a -vn -c:a copy -movflags +faststart -f ipod remuxed.m4a`) : **succès (`rc=0`, 309 137 octets)** ;
2. **Transcodage `.webm` (Opus 251) → `.m4a` (AAC 256 kb/s)** (`ffmpeg -i in.webm -vn -c:a aac -b:a 256k -f ipod transcoded.m4a`) : **succès (`rc=0`, 574 439 octets)** ;
3. **`yt-dlp -f bestaudio[ext=webm] -x --audio-format m4a --audio-quality 256K --ffmpeg-location <ffmpeg>`** : **`[ExtractAudio]` produit directement `.m4a` (`rc=0`)**.

**Conclusion** : `Tools/FFmpeg/build.sh` n'a besoin d'aucun composant supplémentaire. Note macOS : veiller à utiliser `/usr/bin/clang` plutôt qu'un `clang` Homebrew sur `PATH` lors de la compilation de FFmpeg.
