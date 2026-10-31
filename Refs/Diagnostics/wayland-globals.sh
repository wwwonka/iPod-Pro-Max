#!/bin/bash
export XDG_RUNTIME_DIR=/run/user/$(id -u) WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
command -v wayland-info >/dev/null || sudo -n dnf install -y wayland-utils >/dev/null 2>&1 || true
gnome-shell --version 2>/dev/null
if command -v wayland-info >/dev/null; then wayland-info 2>/dev/null | grep -oE "interface: '[a-z_0-9]+'" | sort -u | grep -iE "blur|background|effect|kde" || echo "no blur/background-effect protocol"; else echo "wayland-info unavailable"; fi
