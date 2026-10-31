#!/bin/bash
# Uses a NEW scratch iPod only. Reads the music folder; never modifies source media.
set -euo pipefail
cd "$(dirname "$0")/../.."
MUSIC_FOLDER=${1:?music folder required}
SCRATCH_ROOT=${2:?new scratch folder required}
[ ! -e "$SCRATCH_ROOT" ] || { echo 'Use a new scratch folder.' >&2; exit 1; }
swift build -c release --product ipodpromax >/dev/null
BIN=$(swift build -c release --show-bin-path)
CHECK_BINARY="${TMPDIR:-/tmp}/ippm-portable-check"
xcrun swiftc -O -parse-as-library -o "$CHECK_BINARY" -I "$BIN/Modules" \
    "$BIN"/iPodKit.build/*.o "$BIN"/MediaKit.build/*.o "$BIN"/DeviceKit.build/*.o \
    -framework DiskArbitration -framework IOKit \
    'iPod Pro Max/Platforms/PortablePreferences.swift' 'iPod Pro Max/Platforms/DevicePageCache.swift' \
    'iPod Pro Max/Platforms/PortableRoot.swift' 'iPod Pro Max/Library/PortableLoading.swift' \
    'iPod Pro Max/Library/MusicTransfer.swift' 'iPod Pro Max/UI/TrackDrag.swift' Tools/PortableCheck/main.swift
"$CHECK_BINARY" --music-folder "$MUSIC_FOLDER" --portable-root "$SCRATCH_ROOT"
