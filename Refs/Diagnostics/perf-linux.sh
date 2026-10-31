#!/bin/bash
export XDG_RUNTIME_DIR=/run/user/$(id -u) WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus IPPM_BENCH=6
pkill -x iPodProMaxProto
cd "$HOME/dev/swiftcrossui"
perf record -F 499 -g -o /tmp/ippm.perf -- .build/release/iPodProMaxProto >/dev/null 2>&1
perf report -i /tmp/ippm.perf --no-children --sort dso,sym --stdio 2>/dev/null | grep -v "^#" | grep "%" | head -45
