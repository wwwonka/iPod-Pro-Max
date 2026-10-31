#!/bin/bash
export XDG_RUNTIME_DIR=/run/user/$(id -u) WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus IPPM_BENCH=1 GSK_RENDERER=vulkan IPPM_SLIDE_SECONDS=2
pkill -x iPodProMaxProto
cd "$HOME/dev/swiftcrossui"
perf record -F 997 -g -o /tmp/ippm-slide.perf -- .build/release/iPodProMaxProto 2>&1 | grep sidebar
echo "== inclusive, under the slide's frame callback"
perf report -i /tmp/ippm-slide.perf --no-children --sort dso,sym --stdio -g none 2>/dev/null | grep "%" | head -40
