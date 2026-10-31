#!/bin/zsh
# Builds and runs the dbtest harness against a simulated iPod folder. The engine comes from the
# package at the repository root (iPodKit, MediaKit, DeviceKit, built with `swift build`); the app's
# library and sync code is compiled in with the harness, as the Xcode app does.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/Refs/SwiftUI/iPod Pro Max"
OUT="${TMPDIR:-/tmp}/dbtest"
mkdir -p "$OUT"
(cd "$ROOT" && swift build -c release --target DeviceKit >/dev/null && swift build -c release --target MediaKit >/dev/null)
BIN="$(cd "$ROOT" && swift build -c release --show-bin-path)"
xcrun swiftc -O -target arm64-apple-macos15.0 -parse-as-library -o "$OUT/dbtest" \
  -I "$BIN/Modules" \
  "$BIN"/iPodKit.build/*.o "$BIN"/MediaKit.build/*.o "$BIN"/DeviceKit.build/*.o \
  -framework DiskArbitration -framework IOKit \
  "$SRC"/Device/*.swift "$SRC"/Library/*.swift "$SRC"/Sync/*.swift "$ROOT/Tools/DbTest/main.swift"
"$OUT/dbtest" "$@"
