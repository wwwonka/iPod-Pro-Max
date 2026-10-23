#!/bin/sh
# Builds and runs with GTK 4 (DefaultBackend on Linux). Pass --library <path> to pick a library.json.
set -e
cd "$(dirname "$0")"
swift run iPodProMaxProto "$@"
