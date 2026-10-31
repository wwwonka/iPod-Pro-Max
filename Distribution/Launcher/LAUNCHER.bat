#!/bin/sh
:; # iPod Pro Max launcher: one file read by sh on macOS and Linux and by cmd on Windows.
:; # The #! line is for Linux file managers ("Run as Program" needs it); cmd shows one error for it.
:; # Copied to the iPod's root as LAUNCHER.bat (Windows: double-click; Linux: sh LAUNCHER.bat) and as
:; # LAUNCHER.command (macOS: double-click). "LAUNCHER cli <arguments>" runs the command-line tool.
:; # It copies the app for this OS to the computer and runs that copy, so nothing runs from the iPod.
:; # Docs/Distribution/Lancement portatif par OS.md
:; [ -n "${IPPM_LAUNCHER_SH:-}" ] || IPPM_LAUNCHER_SH=1 exec /bin/sh "$0" "$@"
:<<"::WINDOWS"
@echo off
rem No labels below: cmd finds them unreliably in a file with Unix line endings.
setlocal EnableExtensions EnableDelayedExpansion
set "ROOT=%~dp0"
set "HOME_DIR=!ROOT!iPod Pro Max"
set "ARCH=x64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "ARCH=arm64"
if /i "%PROCESSOR_ARCHITEW6432%"=="ARM64" set "ARCH=arm64"
rem The root without its trailing backslash, except for a drive's root ("E:\", not "E:"). No "\."
rem at the end: Foundation on Windows overflows its stack resolving "\\server\share\folder\.".
set "IPPM_PORTABLE_ROOT=!ROOT:~0,-1!"
if "!IPPM_PORTABLE_ROOT:~-1!"==":" set "IPPM_PORTABLE_ROOT=!ROOT!"
set "WHAT=Applications\Windows\!ARCH!"
set "COPY=%LOCALAPPDATA%\iPod Pro Max\App-!ARCH!"
set "EXE=iPodProMaxApp.exe"
if /i "%~1"=="cli" (
    set "WHAT=Command Line\Windows\!ARCH!"
    set "COPY=%LOCALAPPDATA%\iPod Pro Max\Command Line-!ARCH!"
    set "EXE=ipodpromax.exe"
)
if not exist "!HOME_DIR!\!WHAT!\!EXE!" (
    echo iPod Pro Max: !WHAT!\!EXE! is missing from this iPod.
    if /i not "%~1"=="cli" pause
    exit /b 1
)
fc /b "!HOME_DIR!\version.txt" "!COPY!\version.txt" >nul 2>&1
if errorlevel 1 (
    robocopy "!HOME_DIR!\!WHAT!" "!COPY!" /MIR /NFL /NDL /NJH /NJS /NP >nul
    if errorlevel 8 (
        echo iPod Pro Max: couldn't copy !WHAT! to !COPY!.
        if /i not "%~1"=="cli" pause
        exit /b 1
    )
    copy /y "!HOME_DIR!\version.txt" "!COPY!\version.txt" >nul
)
if /i "%~1"=="cli" (
    set "ARGS=%*"
    set "ARGS=!ARGS:~3!"
    "!COPY!\!EXE!" !ARGS!
    exit /b !errorlevel!
)
rem The app finds the root in IPPM_PORTABLE_ROOT, which start passes on.
start "" /D "!COPY!" "!COPY!\!EXE!"
exit /b 0
::WINDOWS

# macOS and Linux, in POSIX sh.
set -u
fail() {
    printf 'iPod Pro Max: %s\n' "$1" >&2
    # Opened by a double-click (iPod Pro Max.desktop on Linux): no terminal to read it in.
    if [ ! -t 2 ] && [ "$(uname -s)" = Linux ]; then
        zenity --error --title="iPod Pro Max" --text="$1" 2>/dev/null ||
            kdialog --title "iPod Pro Max" --error "$1" 2>/dev/null ||
            notify-send "iPod Pro Max" "$1" 2>/dev/null
    fi
    exit 1
}
root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P) || fail "can't find the iPod's folder."
home="$root/iPod Pro Max"

case $(uname -m) in
    arm64 | aarch64) linux_arch=aarch64 ;;
    x86_64 | amd64) linux_arch=x86_64 ;;
    *) fail "this $(uname -m) computer isn't supported." ;;
esac
case $(uname -s) in
    Darwin)
        os=macOS cache="$HOME/Library/Caches/iPod Pro Max"
        app_folder="Applications/macOS" cli_folder="Command Line/macOS" ;;
    Linux)
        os=Linux cache="${XDG_CACHE_HOME:-$HOME/.cache}/ipod-pro-max"
        app_folder="Applications/Linux/$linux_arch" cli_folder="Command Line/Linux/$linux_arch" ;;
    *) fail "$(uname -s) isn't supported." ;;
esac
export IPPM_PORTABLE_ROOT="$root"

# Copies <folder on the iPod> to <local copy> unless that copy is already this version: nothing then
# runs from the iPod, so it can be ejected, and FAT32 mounted noexec or showexec doesn't matter.
local_copy() {
    [ -d "$home/$1" ] || fail "$1 is missing from this iPod."
    cmp -s "$home/version.txt" "$2/version.txt" 2>/dev/null && return 0
    rm -rf "$2.tmp" && mkdir -p "$2.tmp" && cp -R "$home/$1/." "$2.tmp/" || fail "couldn't copy $1 to $2."
    cp "$home/version.txt" "$2.tmp/version.txt"
    if [ $os = macOS ]; then
        # A download's quarantine survives on FAT32 in ._ files and would translocate the app.
        xattr -dr com.apple.quarantine "$2.tmp" 2>/dev/null
    else
        find "$2.tmp" -name '._*' -exec rm -f {} + 2>/dev/null
    fi
    find "$2.tmp" -type f \( -name iPodProMaxApp -o -name ipodpromax -o -name ffmpeg \) -exec chmod +x {} +
    rm -rf "$2" && mv "$2.tmp" "$2" || fail "couldn't replace $2."
}

if [ "${1:-}" = cli ]; then
    shift
    local_copy "$cli_folder" "$cache/Command Line"
    exec "$cache/Command Line/ipodpromax" "$@"
fi

local_copy "$app_folder" "$cache/App"
case $os in
    macOS) exec open "$cache/App/iPod Pro Max.app" --args --portable-root "$root" ;;
    Linux) (nohup "$cache/App/iPodProMaxApp" --portable-root "$root" >/dev/null 2>&1 </dev/null &) ;;
esac
