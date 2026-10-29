#!/bin/bash
# Runs inside the Fedora VM, called by ../build.sh through prlctl exec.
#   build-linux.sh deps                 (as root)  installs GTK 4 and Swift (Fedora's swift-lang package)
#   build-linux.sh build <source dir>   (as user)  builds, fills dist/linux
#   build-linux.sh run                  (as user)  opens the last build in the desktop session
#   build-linux.sh check                           exits 0 when Swift and GTK 4 are installed
set -euo pipefail

case ${1:-} in
deps)
    # Fedora packages Swift itself; swiftly refuses Fedora releases newer than its support list.
    dnf install -y swift-lang gtk4-devel clang rsync
    ;;
build)
    SRC=$2
    WORK=$HOME/dev/swiftcrossui
    command -v swift >/dev/null || { echo "Swift is missing: run build.sh --setup linux" >&2; exit 1; }
    swift --version

    mkdir -p "$WORK"
    rsync -a --delete --exclude .build --exclude .build-gtk --exclude dist --exclude .swiftpm "$SRC/" "$WORK/"
    cd "$WORK"
    # Static Swift runtime, so the binary only needs GTK 4 from the system. If this toolchain
    # lacks the static libraries, fall back to a build that needs Swift installed to run.
    # Only GTK: left to its platform conditions, SwiftPM also builds the WinUI backend here.
    export SCUI_DEFAULT_BACKEND=GtkBackend
    FLAGS=(-c release --static-swift-stdlib)
    if [ ! -d "$(dirname "$(readlink -f "$(command -v swiftc)")")/../lib/swift_static" ]; then
        echo "This Swift has no static runtime: the binary will need Swift installed to run." >&2
        FLAGS=(-c release)
    fi
    swift package resolve
    bash "$SRC/scripts/patch-dependencies.sh" .build
    swift build "${FLAGS[@]}"
    BIN=$(swift build "${FLAGS[@]}" --show-bin-path)

    # SF Symbols font for the icons, if downloaded into local/ (never committed: see Symbols.swift).
    if [ -f "$SRC/local/SF-SYMBOLS4.TTF" ]; then
        mkdir -p "$HOME/.local/share/fonts"
        if ! cmp -s "$SRC/local/SF-SYMBOLS4.TTF" "$HOME/.local/share/fonts/SF-SYMBOLS4.TTF"; then
            cp "$SRC/local/SF-SYMBOLS4.TTF" "$HOME/.local/share/fonts/" && fc-cache -f "$HOME/.local/share/fonts"
        fi
    fi

    DIST=$SRC/dist/linux
    # rsync rather than rm -rf + cp: deleting a folder on the Parallels share fails now and then.
    mkdir -p "$DIST"
    rsync -a --delete --include 'iPodProMaxProto' --include '*.resources/***' --exclude '*' "$BIN/" "$DIST/"
    echo "OK: $DIST/iPodProMaxProto"
    ;;
check)
    command -v swift >/dev/null && rpm -q gtk4-devel >/dev/null
    ;;
run)
    # prlctl exec does not inherit the desktop session's environment: point GTK at it.
    export XDG_RUNTIME_DIR=/run/user/$(id -u)
    export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
    export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
    pkill -x iPodProMaxProto || true
    cd "$HOME/dev/swiftcrossui"
    # GTK's GL renderer stalls the first slides in the VM (virtio GPU); Vulkan doesn't.
    export GSK_RENDERER=${GSK_RENDERER:-vulkan}
    setsid nohup .build/release/iPodProMaxProto >/tmp/iPodProMaxProto.log 2>&1 </dev/null &
    echo "Launched (log: /tmp/iPodProMaxProto.log)"
    ;;
*)
    echo "usage: $0 deps | build <source dir> | run | check" >&2
    exit 2
    ;;
esac
