#!/bin/bash
export XDG_RUNTIME_DIR=/run/user/$(id -u) WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus IPPM_BENCH=1 GSK_RENDERER=vulkan
pkill -x iPodProMaxProto
cd "$HOME/dev/swiftcrossui" && timeout 120 .build/release/iPodProMaxProto 2>&1 | grep -vE "^\[proto\]"
