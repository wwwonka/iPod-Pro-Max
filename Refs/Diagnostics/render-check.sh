#!/bin/bash
export XDG_RUNTIME_DIR=/run/user/$(id -u) WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
echo "== GL renderer"; (command -v glxinfo >/dev/null && glxinfo -B 2>/dev/null | grep -iE "renderer|accel") || ls /dev/dri 2>&1
echo "== GPU driver"; lspci -k 2>/dev/null | grep -iA2 vga
pkill -x iPodProMaxProto
cd "$HOME/dev/swiftcrossui"
IPPM_BENCH=1 GSK_DEBUG=renderer .build/release/iPodProMaxProto > /tmp/ippm-bench.log 2>&1 &
sleep 4
echo "== CPU during the slides (top, 3 samples)"
top -b -d 1 -n 3 | grep -E "gnome-shell|iPodProMax|Xwayland" | head -9
wait
grep -iE "renderer|bench\] sidebar" /tmp/ippm-bench.log | head -8
