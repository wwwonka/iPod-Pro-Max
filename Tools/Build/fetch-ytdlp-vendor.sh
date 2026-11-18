#!/bin/bash
# Downloads pinned yt-dlp and Deno binaries with SHA256 verification into Plug-ins/yt-dlp/vendor/.
# Mirrors Tools/FFmpeg/build.sh: nothing to install on the host, reproducible across CI and local builds.
#
#   Tools/Build/fetch-ytdlp-vendor.sh            # all platforms (for multi-OS Build/ assembly)
#   Tools/Build/fetch-ytdlp-vendor.sh macos      # only macos
#   Tools/Build/fetch-ytdlp-vendor.sh linux      # only linux-x86_64 and linux-aarch64
#   Tools/Build/fetch-ytdlp-vendor.sh windows    # only windows-x64 and windows-arm64
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
VENDOR="$ROOT/Plug-ins/yt-dlp/vendor"
CACHE="${IPPM_YTDLP_CACHE:-$ROOT/.build-work/ytdlp-cache}"
mkdir -p "$CACHE" "$VENDOR"

YTDLP_VERSION="2026.10.26"
DENO_VERSION="2.9.8"

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

fetch() { # <url> <cache_rel> <expected_sha256>
    local url=$1 file="$CACHE/$2" expected=$3
    mkdir -p "$(dirname "$file")"
    if [ -f "$file" ]; then
        local existing
        existing=$(sha256_file "$file")
        if [ "$existing" != "$expected" ]; then
            rm -f "$file"
        fi
    fi
    if [ ! -f "$file" ]; then
        echo "Downloading $2…"
        curl -fsSL -o "$file.part" "$url" && mv "$file.part" "$file"
    fi
    local actual
    actual=$(sha256_file "$file")
    if [ "$actual" != "$expected" ]; then
        echo "Checksum mismatch for $2: expected $expected, got $actual" >&2
        rm -f "$file"
        exit 1
    fi
}

install_bin() { # <url> <cache_name> <sha256> <dest_path>
    local url=$1 name=$2 sum=$3 dest=$4
    fetch "$url" "$name" "$sum"
    mkdir -p "$(dirname "$dest")"
    cp "$CACHE/$name" "$dest"
    chmod +x "$dest" 2>/dev/null || true
}

install_deno_zip() { # <target_triple> <sha256> <dest_dir> <bin_name>
    local triple=$1 sum=$2 destdir=$3 bin=$4
    local zipfile="deno-${DENO_VERSION}-${triple}.zip"
    local url="https://github.com/denoland/deno/releases/download/v${DENO_VERSION}/deno-${triple}.zip"
    fetch "$url" "$zipfile" "$sum"
    mkdir -p "$destdir"
    rm -rf "$CACHE/unzip-${triple}"
    mkdir -p "$CACHE/unzip-${triple}"
    unzip -q -o "$CACHE/$zipfile" -d "$CACHE/unzip-${triple}"
    cp "$CACHE/unzip-${triple}/${bin}" "$destdir/${bin}"
    chmod +x "$destdir/${bin}" 2>/dev/null || true
    rm -rf "$CACHE/unzip-${triple}"
}

fetch_macos() {
    local base="https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}"
    install_bin "$base/yt-dlp_macos" "yt-dlp_${YTDLP_VERSION}_macos" \
        "0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa" \
        "$VENDOR/macos/yt-dlp"
    install_deno_zip "aarch64-apple-darwin" \
        "9f0bf660393da2eaff044cdc7444cb08c73f235849b61d224d825a194ce7c98e" \
        "$VENDOR/macos-arm64" "deno"
    install_deno_zip "x86_64-apple-darwin" \
        "4b2f5edd2639b7470f034238b321d7002d8dfb4726d8558f52c17afac370eb2c" \
        "$VENDOR/macos-x64" "deno"
    if [ "$(uname -s)" = "Darwin" ]; then
        codesign --force --sign - "$VENDOR/macos/yt-dlp" "$VENDOR/macos-arm64/deno" "$VENDOR/macos-x64/deno"
    fi
    echo "OK: yt-dlp + deno for macOS"
}

fetch_windows() {
    local base="https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}"
    install_bin "$base/yt-dlp.exe" "yt-dlp_${YTDLP_VERSION}.exe" \
        "f5389d3698ecde4ef06f4e6b1ce0294fe9ac1396228c8990b8d3416d6d177a7d" \
        "$VENDOR/windows-x64/yt-dlp.exe"
    install_deno_zip "x86_64-pc-windows-msvc" \
        "cba84b26e0df5ae7f74fc66b86a95b866872a86292ebd84fa1e959927edd93bf" \
        "$VENDOR/windows-x64" "deno.exe"
    install_deno_zip "aarch64-pc-windows-msvc" \
        "b413b92b735b50c198e8fe3b85af1aa50e29d5f72e229aab701d132286e14cef" \
        "$VENDOR/windows-arm64" "deno.exe"
    echo "OK: yt-dlp + deno for Windows"
}

fetch_linux() {
    local base="https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}"
    install_bin "$base/yt-dlp_linux" "yt-dlp_${YTDLP_VERSION}_linux" \
        "767ba9dce7052aa196f8b12652f433d76de128ba168966fa84b6394d5e6c6795" \
        "$VENDOR/linux-x86_64/yt-dlp"
    install_bin "$base/yt-dlp_linux_aarch64" "yt-dlp_${YTDLP_VERSION}_linux_aarch64" \
        "e87e9533e89fe5889abaa21f5114dfe7756d6aa6219b83551add04d48b18e483" \
        "$VENDOR/linux-aarch64/yt-dlp"
    install_deno_zip "x86_64-unknown-linux-gnu" \
        "e890975bc2549807bbcc0b584ffafda72cc7c93349dd99c80483dd784f6c4609" \
        "$VENDOR/linux-x86_64" "deno"
    install_deno_zip "aarch64-unknown-linux-gnu" \
        "d49596c20b9788cf8f5d8ddf644103d4bde56ed239753f0bdb92ba9361d51905" \
        "$VENDOR/linux-aarch64" "deno"
    echo "OK: yt-dlp + deno for Linux"
}

TARGET=${1:-all}
case "$TARGET" in
    all) fetch_macos; fetch_windows; fetch_linux ;;
    macos) fetch_macos ;;
    windows) fetch_windows ;;
    linux) fetch_linux ;;
    *) echo "usage: $0 [all|macos|windows|linux]" >&2; exit 2 ;;
esac
