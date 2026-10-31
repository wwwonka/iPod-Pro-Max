#!/bin/bash
# Double-click in Finder: builds the SwiftCrossUI application for macOS, then opens it.
# Same as: Tools/Build/build.sh mac --run
cd "$(dirname "$0")"
if Tools/Build/build.sh mac --run; then
    echo; echo "Done."
else
    echo; echo "Build failed (see above)."
    read -r -n 1 -p "Press a key to close…"
fi
