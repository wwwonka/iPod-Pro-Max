#!/bin/bash
# Runs inside the Fedora VM, called by ../build.sh through prlctl exec.
#   build-linux.sh deps                 (as root)  installs GTK 4 and Swift (Fedora's swift-lang package)
#   build-linux.sh build <source dir>   (as user)  builds, fills Build/linux
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
    rsync -a --delete --exclude .build --exclude .build-gtk --exclude /Build/ --exclude Local --exclude Legacy --exclude Docs --exclude Site --exclude Refs --exclude .git --exclude .claude --exclude .scratch --exclude .swiftpm --exclude .cache "$SRC/" "$WORK/"
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
    bash "$SRC/Tools/Build/patch-dependencies.sh" .build
    swift build "${FLAGS[@]}" --product iPodProMaxApp
    BIN=$(swift build "${FLAGS[@]}" --show-bin-path)

    # The app's icon and .desktop file, for the user: GNOME finds a window's icon from the .desktop
    # file named after its application id (WindowChrome.swift's appIdentifier).
    APP_ID=com.ipodpromax.proto
    for size in 16 32 128 256 512; do
        dir="$HOME/.local/share/icons/hicolor/${size}x${size}/apps"
        mkdir -p "$dir"
        cp "$SRC/iPod Pro Max/Resources/AppIcon.appiconset/icon_${size}x${size}@1x.png" "$dir/$APP_ID.png"
    done
    mkdir -p "$HOME/.local/share/applications"
    cat > "$HOME/.local/share/applications/$APP_ID.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=iPod Pro Max
Exec=$WORK/.build/release/iPodProMaxApp
Icon=$APP_ID
StartupWMClass=$APP_ID
DESKTOP

    # SF Symbols font for the icons, if downloaded into local/ (never committed: see Symbols.swift).
    if [ -f "$SRC/iPod Pro Max/Resources/Local/SF-SYMBOLS4.TTF" ]; then
        mkdir -p "$HOME/.local/share/fonts"
        if ! cmp -s "$SRC/iPod Pro Max/Resources/Local/SF-SYMBOLS4.TTF" "$HOME/.local/share/fonts/SF-SYMBOLS4.TTF"; then
            cp "$SRC/iPod Pro Max/Resources/Local/SF-SYMBOLS4.TTF" "$HOME/.local/share/fonts/" && fc-cache -f "$HOME/.local/share/fonts"
        fi
    fi

    DIST=$SRC/Build/linux
    # rsync rather than rm -rf + cp: deleting a folder on the Parallels share fails now and then.
    mkdir -p "$DIST"
    rsync -a --delete --include 'iPodProMaxApp' --include '*.resources/***' --exclude '*' "$BIN/" "$DIST/"
    # The app's own ffmpeg (Tools/FFmpeg/build.sh), next to the executable where MediaKit looks.
    FFMPEG="$SRC/Build/FFmpeg/linux-$(uname -m | sed 's/aarch64/arm64/; s/x86_64/x64/')/ffmpeg"
    if [ -x "$FFMPEG" ]; then cp "$FFMPEG" "$DIST/ffmpeg"; else echo "warning: ffmpeg not built (Tools/FFmpeg/build.sh)" >&2; fi
    echo "OK: $DIST/iPodProMaxApp"
    ;;
check)
    command -v swift >/dev/null && rpm -q gtk4-devel >/dev/null
    ;;
run)
    # prlctl exec does not inherit the desktop session's environment: point GTK at it.
    export XDG_RUNTIME_DIR=/run/user/$(id -u)
    export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
    export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
    pkill -x iPodProMaxApp || true
    cd "$HOME/dev/swiftcrossui"
    # GTK's GL renderer stalls the first slides in the VM (virtio GPU); Vulkan doesn't.
    export GSK_RENDERER=${GSK_RENDERER:-vulkan}
    setsid nohup .build/release/iPodProMaxApp >/tmp/iPodProMaxApp.log 2>&1 </dev/null &
    echo "Launched (log: /tmp/iPodProMaxApp.log)"
    ;;
*)
    echo "usage: $0 deps | build <source dir> | run | check" >&2
    exit 2
    ;;
esac
