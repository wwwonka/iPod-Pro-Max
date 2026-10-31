#!/bin/bash
export XDG_RUNTIME_DIR=/run/user/$(id -u) WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus IPPM_BENCH=1
cd "$HOME/dev/swiftcrossui"
for r in gl cairo vulkan; do
    pkill -x iPodProMaxProto; sleep 1
    echo "== GSK_RENDERER=$r"
    GSK_RENDERER=$r timeout 60 .build/release/iPodProMaxProto 2>&1 | grep -E "bench\] (sidebar|Music)" | head -6
done
