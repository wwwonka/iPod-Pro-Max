#!/bin/bash
# Builds the SwiftCrossUI prototype for macOS (AppKit), signed ad hoc.
#
#   ./build-mac.sh         # -> prototypes/swiftcrossui/dist/mac/iPod Pro Max Proto.app
#   ./build-mac.sh --run   # also opens it
#
# Shortcut for prototypes/swiftcrossui/build.sh mac; see that folder's README.
set -euo pipefail
exec "$(dirname "$0")/prototypes/swiftcrossui/build.sh" mac "$@"
