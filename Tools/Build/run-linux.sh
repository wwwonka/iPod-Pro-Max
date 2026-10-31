#!/bin/sh
# Builds and runs in the Linux VM by hand (build.sh does this for you). Pass --library <path> to
# pick a library.json.
set -e
cd "$(dirname "$0")/../.."
# Only GTK: otherwise SwiftPM also builds the WinUI backend and fails.
export SCUI_DEFAULT_BACKEND=GtkBackend
swift package resolve
Tools/Build/patch-dependencies.sh .build
swift run iPodProMaxApp "$@"
