#!/bin/bash
# Makes the app icon for each platform from iPod Pro Max/Resources/AppIcon.appiconset (the one source):
#   Build/icons/AppIcon.icns  (macOS bundle)    Build/icons/AppIcon.ico  (Windows executable and window)
# Linux takes the PNGs as they are (Tools/Build/build-linux.sh). macOS only: uses iconutil.
set -euo pipefail
cd "$(dirname "$0")/../.."
src="iPod Pro Max/Resources/AppIcon.appiconset"
out=Build/icons
mkdir -p "$out"
[ "$out/AppIcon.ico" -nt "$src" ] && [ "$out/AppIcon.icns" -nt "$src" ] && exit 0

# iconutil wants the iconset names without "@1x".
set_dir=$(mktemp -d)/AppIcon.iconset
mkdir -p "$set_dir"
for f in "$src"/icon_*.png; do cp "$f" "$set_dir/$(basename "$f" | sed 's/@1x//')"; done
iconutil -c icns "$set_dir" -o "$out/AppIcon.icns"

# An .ico holding PNGs (Windows Vista and later read them): 16, 32, 64, 128 and 256 px.
python3 -I - "$out/AppIcon.ico" "$src"/icon_16x16@1x.png "$src"/icon_32x32@1x.png "$src"/icon_32x32@2x.png \
    "$src"/icon_128x128@1x.png "$src"/icon_256x256@1x.png <<'PY'
import struct, sys
out, pngs = sys.argv[1], [open(p, 'rb').read() for p in sys.argv[2:]]
entries, offset = b'', 6 + 16 * len(pngs)
for png in pngs:
    w, h = struct.unpack('>II', png[16:24])
    entries += struct.pack('<BBBBHHII', w % 256, h % 256, 0, 0, 1, 32, len(png), offset)
    offset += len(png)
open(out, 'wb').write(struct.pack('<HHH', 0, 1, len(pngs)) + entries + b''.join(pngs))
PY
echo "make-icons: $out/AppIcon.icns, $out/AppIcon.ico"
