#!/bin/bash
# Double-click in Finder: builds iPod Pro Max for macOS, Windows and Linux, lays Build/ out as the
# root of an iPod, then shows it. Same as: Tools/Build/build.sh (see it for options).
cd "$(dirname "$0")"
if Tools/Build/build.sh "$@"; then
    open Build
    echo; echo "Done: Build/ is the iPod. Double-click Build/LAUNCHER.command to run the app."
else
    echo; echo "Build failed (see above, or .build-work/<os>.log)."
    read -r -n 1 -p "Press a key to close…"
fi
