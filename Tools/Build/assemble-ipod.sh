#!/bin/bash
# Lays Build/ out as the root of an iPod formatted for Windows (FAT32), from what build.sh left in
# .build-work/. Nothing here touches a real iPod. Docs/Données/Sur l'iPod.md.
#
#   Tools/Build/assemble-ipod.sh            # keeps iPod_Control/ and iPod Pro Max/Persistent Data/
#   Tools/Build/assemble-ipod.sh --clean    # starts Build/ over, those two included
#
# Build/
#   LAUNCHER.bat, LAUNCHER.command          one polyglot file (Distribution/Launcher/LAUNCHER.bat)
#   iPod_Control/                           generated when missing, then never touched
#   <Distribution/iPod Root/>               copied as is
#   iPod Pro Max/
#     Applications/macOS/iPod Pro Max.app, Applications/Windows/<x64|arm64>/, Applications/Linux/<x86_64|aarch64>/
#     Command Line/macOS/, Command Line/Windows/<arch>/, Command Line/Linux/<arch>/
#     version.txt                           a new one per assembly: the launcher recopies the app
#     Persistent Data/                      settings and records written by the app and the CLI
set -euo pipefail
cd "$(dirname "$0")/../.."
WORK=.build-work
OUT=Build
APP="$OUT/iPod Pro Max"

if [ "${1:-}" = --clean ]; then
    echo "Starting Build/ over (iPod_Control and Persistent Data included)."
    rm -rf "$OUT"
fi
mkdir -p "$APP"
# What the build put in Build/ before it became an iPod root.
rm -rf "$OUT/LAUNCHER.cmd" "$OUT/mac" "$OUT/linux" "$OUT/windows" "$OUT/icons" "$OUT/FFmpeg" "$OUT"/*.log "$OUT"/windows-vm.*

# Assets: added and updated, never deleted (Build/ is an iPod: what the app syncs there stays).
rsync -a --exclude .DS_Store --exclude /iPod_Control/ "Distribution/iPod Root/" "$OUT/"

# The applications and the command-line tool: mirrors of .build-work, one folder per OS and architecture.
place() { # <.build-work folder> <folder under iPod Pro Max/>
    local from="$WORK/$1" to="$APP/$2"
    if [ -d "$from" ] && [ -n "$(ls -A "$from")" ]; then
        mkdir -p "$to"
        rsync -a --delete --exclude .DS_Store "$from/" "$to/"
        echo "  $2"
    fi
}
echo "Build/iPod Pro Max:"
place mac/app "Applications/macOS"
place mac/cli "Command Line/macOS"
for arch in x64 arm64; do
    place "windows/$arch" "Applications/Windows/$arch"
    place "windows-cli/$arch" "Command Line/Windows/$arch"
    # ffmpeg for Windows is built in the Linux container, possibly after the VM's build.
    for dir in "Applications/Windows/$arch" "Command Line/Windows/$arch"; do
        [ -d "$APP/$dir" ] && [ -f "$WORK/FFmpeg/windows-$arch/ffmpeg.exe" ] && cp "$WORK/FFmpeg/windows-$arch/ffmpeg.exe" "$APP/$dir/"
    done
done
for arch in x86_64 aarch64; do
    place "linux/$arch" "Applications/Linux/$arch"
    place "linux-cli/$arch" "Command Line/Linux/$arch"
done

# The launcher, under the names each OS opens with a double-click (same bytes).
for name in LAUNCHER.bat LAUNCHER.command; do
    cp Distribution/Launcher/LAUNCHER.bat "$OUT/$name"
    chmod +x "$OUT/$name"
done
# Linux: a double-click on it runs LAUNCHER.bat without a terminal.
cp "Distribution/Launcher/iPod Pro Max.desktop" "$OUT/"
chmod +x "$OUT/iPod Pro Max.desktop"
{ git rev-parse --short HEAD 2>/dev/null || echo unknown; date -u +%Y-%m-%dT%H:%M:%SZ; } > "$APP/version.txt"
mkdir -p "$APP/Persistent Data"

# The iPod's own folder: generated once, then left alone, so what is synced to Build/ stays.
if [ ! -d "$OUT/iPod_Control" ]; then
    if [ -d "Distribution/iPod Root/iPod_Control" ]; then
        rsync -a --exclude .DS_Store "Distribution/iPod Root/iPod_Control/" "$OUT/iPod_Control/"
        echo "iPod_Control: copied from Distribution/iPod Root"
    elif [ -x "$WORK/mac/cli/ipodpromax" ]; then
        "$WORK/mac/cli/ipodpromax" init-sim "$OUT" --name "iPod Pro Max" >/dev/null
        echo "iPod_Control: generated (simulated iPod)"
    else
        echo "warning: no iPod_Control yet: build the Mac command-line tool (build.sh mac)." >&2
    fi
fi
echo "OK: $(pwd)/$OUT"
