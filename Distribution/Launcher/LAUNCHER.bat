#!/bin/sh
:; # iPod Pro Max launcher: one file read by sh on macOS and Linux and by cmd on Windows.
:; # The #! line is for Linux file managers ("Run as Program" needs it); cmd shows one error for it.
:; # Copied to the iPod's root as LAUNCHER.bat (Windows: double-click; Linux: sh LAUNCHER.bat) and as
:; # LAUNCHER.command (macOS: double-click). "LAUNCHER cli <arguments>" runs the command-line tool.
:; # Runs from the iPod. No application copy or library cache is created on the computer.
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

set "EXE=iPodProMaxApp.exe"
if /i "%~1"=="cli" (
    set "WHAT=Command Line\Windows\!ARCH!"

    set "EXE=ipodpromax.exe"
)
if not exist "!HOME_DIR!\!WHAT!\!EXE!" (
    echo iPod Pro Max: !WHAT!\!EXE! is missing from this iPod.
    if /i not "%~1"=="cli" pause
    exit /b 1
)
if /i "%~1"=="cli" (
    set "ARGS=%*"
    set "ARGS=!ARGS:~3!"
    "!HOME_DIR!\!WHAT!\!EXE!" !ARGS!
    exit /b !errorlevel!
)
rem The app finds the root in IPPM_PORTABLE_ROOT, which start passes on.
start "" /D "!HOME_DIR!\!WHAT!" "!HOME_DIR!\!WHAT!\!EXE!"
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
app_root="$root/iPod Pro Max"

case $(uname -m) in
    arm64 | aarch64) linux_arch=aarch64 ;;
    x86_64 | amd64) linux_arch=x86_64 ;;
    *) fail "this $(uname -m) computer isn't supported." ;;
esac
case $(uname -s) in
    Darwin)
        os=macOS
        app_folder="Applications/macOS" cli_folder="Command Line/macOS" ;;
    Linux)
        os=Linux
        app_folder="Applications/Linux/$linux_arch" cli_folder="Command Line/Linux/$linux_arch" ;;
    *) fail "$(uname -s) isn't supported." ;;
esac
export IPPM_PORTABLE_ROOT="$root"

# Executable mounts are required on Linux. Do not silently fall back to host storage.
if [ "${1:-}" = cli ]; then
    shift
    [ -x "$app_root/$cli_folder/ipodpromax" ] || fail "CLI is missing or this volume does not allow execution."
    exec "$app_root/$cli_folder/ipodpromax" "$@"
fi

case $os in
    macOS) exec open "$app_root/$app_folder/iPod Pro Max.app" --args --portable-root "$root" ;;
    Linux)
        [ -x "$app_root/$app_folder/iPodProMaxApp" ] || fail "Application is missing or this volume does not allow execution."
        (nohup "$app_root/$app_folder/iPodProMaxApp" --portable-root "$root" >/dev/null 2>&1 </dev/null &) ;;
esac
