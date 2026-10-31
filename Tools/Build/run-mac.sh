#!/bin/sh
# ./run-mac.sh       -> AppKit (native)
# ./run-mac.sh gtk   -> GTK 4 via Homebrew, to preview the Linux look on the Mac
set -e
cd "$(dirname "$0")/../.."
if [ "$1" = "gtk" ]; then
    export SCUI_DEFAULT_BACKEND=GtkBackend
    export PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig"
    swift package resolve --scratch-path .build-gtk
    Tools/Build/patch-dependencies.sh .build-gtk
    swift run --scratch-path .build-gtk iPodProMaxApp
else
    swift package resolve
    Tools/Build/patch-dependencies.sh .build
    swift run iPodProMaxApp
fi
