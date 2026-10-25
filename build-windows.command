#!/bin/bash
# Double-click in Finder: builds the SwiftCrossUI prototype for Windows 11 (VM Parallels « Windows 11 »), then opens it.
# First run installs Visual Studio, Swift and WinUI in the VM: long, and Windows asks for admin approval.
# Same as: prototypes/swiftcrossui/build.sh windows --run
cd "$(dirname "$0")"
if prototypes/swiftcrossui/build.sh windows --run; then
    echo; echo "Done."
else
    echo; echo "Build failed (see above, or prototypes/swiftcrossui/dist/windows.log)."
    read -r -n 1 -p "Press a key to close…"
fi
