#!/bin/bash
# Reads connected iPods. Preference-write checks use the supplied simulated iPod only.
set -euo pipefail
cd "$(dirname "$0")/../.."
SCRATCH_IPOD=${1:?existing simulated iPod required}
swift build -c release --product ipodpromax >/dev/null
BIN=$(swift build -c release --show-bin-path)
OUT="${TMPDIR:-/tmp}/ippm-device-page-check"
xcrun swiftc -O -parse-as-library -I "$BIN/Modules" -o "$OUT" \
    "$BIN"/iPodKit.build/*.o "$BIN"/DeviceKit.build/*.o \
    -framework DiskArbitration -framework IOKit \
    'iPod Pro Max/Platforms/PortableRoot.swift' 'iPod Pro Max/Platforms/DevicePageCache.swift' \
    Tools/DevicePageCheck/main.swift
"$OUT" --portable-root "$SCRATCH_IPOD"
