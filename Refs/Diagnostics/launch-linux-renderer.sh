#!/bin/bash
export XDG_RUNTIME_DIR=/run/user/$(id -u) WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
pkill -x iPodProMaxProto; sleep 0.5
cd "$HOME/dev/swiftcrossui"
[ -n "$1" ] && export GSK_RENDERER=$1
setsid nohup .build/release/iPodProMaxProto >/tmp/ippm-r.log 2>&1 </dev/null &
echo started
