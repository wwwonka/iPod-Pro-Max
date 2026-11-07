#!/usr/bin/env bash
# Run as root in a disposable Linux VM. Never touches an existing device.
set -eu
work=$(mktemp -d /tmp/ippm-fat-test.XXXXXXXX)
loop=''
cleanup() {
    if mountpoint -q "$work/mnt"; then umount "$work/mnt" || true; fi
    if [ -n "$loop" ]; then losetup -d "$loop" || true; fi
    rm -rf "$work"
}
trap cleanup EXIT
mkdir "$work/mnt"
truncate -s 128M "$work/volume.img"
mkfs.fat -F 32 -n IPOD "$work/volume.img" >/dev/null
loop=$(losetup --find --show "$work/volume.img")
mount -t vfat "$loop" "$work/mnt"
python3 - "$1" "$loop" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('fat', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.patch(sys.argv[2], b'iPod Linux ', device_size=128 * 1024 * 1024)
PY
printf test > "$work/mnt/activity"
sync
umount "$work/mnt"
fsck.fat -n "$loop"
fatlabel "$loop"
