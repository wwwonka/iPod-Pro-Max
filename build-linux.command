#!/bin/bash
# Double-click in Finder: builds the SwiftCrossUI prototype for Fedora (VM Parallels « Fedora Linux »), then opens it.
# First run installs GTK 4 and Swift in the VM (a few minutes).
# Same as: prototypes/swiftcrossui/build.sh linux --run
cd "$(dirname "$0")"
if prototypes/swiftcrossui/build.sh linux --run; then
    echo; echo "Done."
else
    echo; echo "Build failed (see above, or prototypes/swiftcrossui/dist/linux.log)."
    read -r -n 1 -p "Press a key to close…"
fi
