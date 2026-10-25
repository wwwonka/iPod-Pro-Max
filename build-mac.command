#!/bin/bash
# Double-click in Finder: builds the SwiftCrossUI prototype for macOS, then opens it.
# Same as: prototypes/swiftcrossui/build.sh mac --run
cd "$(dirname "$0")"
if prototypes/swiftcrossui/build.sh mac --run; then
    echo; echo "Done."
else
    echo; echo "Build failed (see above)."
    read -r -n 1 -p "Press a key to close…"
fi
