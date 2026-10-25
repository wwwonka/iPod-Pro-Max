#!/bin/bash
# Runs inside the Fedora VM, called by ../build.sh through prlctl exec.
#   build-linux.sh deps                 (as root)  installs GTK 4 and the Swift toolchain's dependencies
#   build-linux.sh build <source dir>   (as user)  installs Swift with swiftly if missing, builds, fills dist/linux
set -euo pipefail

case ${1:-} in
deps)
    dnf install -y gtk4-devel clang rsync curl tar gzip \
        binutils gcc git unzip libcurl-devel libedit-devel libicu-devel \
        sqlite-devel libuuid-devel libxml2-devel python3-devel
    ;;
build)
    SRC=$2
    WORK=$HOME/dev/swiftcrossui
    SWIFTLY_ENV=${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh
    [ -f "$SWIFTLY_ENV" ] && . "$SWIFTLY_ENV"
    if ! command -v swift >/dev/null; then
        echo "Installing Swift with swiftly…"
        tmp=$(mktemp -d)
        curl -fsSL "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz" | tar xz -C "$tmp"
        "$tmp/swiftly" init --assume-yes --quiet-shell-followup --skip-install
        . "$SWIFTLY_ENV"
        swiftly install latest --assume-yes --use
        hash -r
    fi
    swift --version

    mkdir -p "$WORK"
    rsync -a --delete --exclude .build --exclude .build-gtk --exclude dist --exclude .swiftpm "$SRC/" "$WORK/"
    cd "$WORK"
    # Static Swift runtime: the binary only needs GTK 4 from the system.
    swift build -c release --static-swift-stdlib
    BIN=$(swift build -c release --static-swift-stdlib --show-bin-path)

    DIST=$SRC/dist/linux
    rm -rf "$DIST"
    mkdir -p "$DIST"
    cp "$BIN/iPodProMaxProto" "$DIST/"
    for r in "$BIN"/*.resources; do [ -e "$r" ] && cp -R "$r" "$DIST/"; done
    echo "OK: $DIST/iPodProMaxProto"
    ;;
*)
    echo "usage: $0 deps | build <source dir>" >&2
    exit 2
    ;;
esac
