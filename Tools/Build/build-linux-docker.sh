#!/bin/bash
# Builds the Linux app and command-line tool on the Mac, in Docker (OrbStack): no VM.
#
#   Tools/Build/build-linux-docker.sh                   # x86_64 and aarch64
#   Tools/Build/build-linux-docker.sh aarch64
#
# Output, read by assemble-ipod.sh:
#   .build-work/linux/<arch>/       iPodProMaxApp (static Swift runtime; GTK 4 and glibc from the
#                                   system) and ffmpeg
#   .build-work/linux-cli/<arch>/   ipodpromax, fully static (musl): runs on any Linux of that architecture
#
# Built on Ubuntu 22.04 (glibc 2.35, GTK 4.6), so the app runs on that and later distributions.
# Caches (SwiftPM, the static SDK, ffmpeg's build) stay in .build-work/linux-docker/<arch>/.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
WORK="$ROOT/.build-work"
SWIFT_IMAGE=swift:6.1.2-jammy
# The static Linux SDK of the same Swift version (swift.org/documentation/articles/static-linux-getting-started).
SDK_URL=https://download.swift.org/swift-6.1.2-release/static-sdk/swift-6.1.2-RELEASE/swift-6.1.2-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz
SDK_SHA256=df0b40b9b582598e7e3d70c82ab503fd6fbfdff71fd17e7f1ab37115a0665b3b

ARCHS=("$@")
[ ${#ARCHS[@]} -eq 0 ] && ARCHS=(x86_64 aarch64)

# OrbStack starts its Docker engine on demand; wait for it, a minute at most.
if ! docker info >/dev/null 2>&1; then
    echo "Starting Docker (OrbStack)…"
    open -ga OrbStack 2>/dev/null || true
    for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 1; done
    docker info >/dev/null 2>&1 || { echo "Docker doesn't answer: start OrbStack, then run again." >&2; exit 1; }
fi

mkdir -p "$WORK/linux-docker"
SDK_FILE="$WORK/linux-docker/$(basename "$SDK_URL")"
if [ ! -f "$SDK_FILE" ]; then
    echo "Downloading the static Linux SDK (once)…"
    curl -fsSL -o "$SDK_FILE.part" "$SDK_URL" && mv "$SDK_FILE.part" "$SDK_FILE"
fi
[ "$(shasum -a 256 "$SDK_FILE" | cut -d' ' -f1)" = "$SDK_SHA256" ] || { echo "Checksum mismatch: $SDK_FILE" >&2; rm -f "$SDK_FILE"; exit 1; }

for arch in "${ARCHS[@]}"; do
    case $arch in
        x86_64) platform=linux/amd64 ffarch=x64 ;;
        aarch64) platform=linux/arm64 ffarch=arm64 ;;
        *) echo "Unknown architecture: $arch (x86_64 or aarch64)" >&2; exit 2 ;;
    esac
    image="ipodpromax-linux-build:$arch"
    # GTK 4 for the app; what Tools/FFmpeg/build.sh needs (compilers, static libstdc++, nasm).
    docker build -q --platform "$platform" -t "$image" - >/dev/null <<EOF
FROM $SWIFT_IMAGE
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libgtk-4-dev rsync build-essential nasm pkg-config curl xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*
EOF
    cache="$WORK/linux-docker/$arch"
    mkdir -p "$cache" "$WORK/linux/$arch" "$WORK/linux-cli/$arch"
    echo "Building for Linux ${arch}…"
    docker run --rm --platform "$platform" \
        -v "$ROOT:/src:ro" -v "$cache:/work" -v "$WORK:/out" -v "$SDK_FILE:/sdk.tar.gz:ro" \
        -e ARCH="$arch" -e FFARCH="$ffarch" "$image" bash -euo pipefail -c '
        # A copy of the sources: building on the Mac share is slow, and .build must stay per architecture.
        rsync -a --delete --exclude /.build/ --exclude /.build-gtk/ --exclude /Build/ --exclude /.build-work/ \
            --exclude /Refs/ --exclude /Docs/ --exclude /.git/ --exclude /.claude/ --exclude /.scratch/ \
            --exclude /.swiftpm/ --exclude Local --exclude .cache --exclude /Tools/FFmpeg/.cache/ /src/ /work/src/
        cd /work/src

        # Our ffmpeg, built once per architecture from pinned sources.
        if [ ! -x /out/FFmpeg/linux-$FFARCH/ffmpeg ]; then
            IPPM_FFMPEG_CACHE=/work/ffmpeg-cache Tools/FFmpeg/build.sh
            mkdir -p /out/FFmpeg && rsync -a .build-work/FFmpeg/ /out/FFmpeg/
        fi

        # The app: static Swift runtime, GTK only (SwiftPM would also build the WinUI backend).
        export SCUI_DEFAULT_BACKEND=GtkBackend
        swift package resolve
        bash Tools/Build/patch-dependencies.sh .build
        swift build -c release --static-swift-stdlib --product iPodProMaxApp
        bin=$(swift build -c release --static-swift-stdlib --show-bin-path)
        rsync -a --delete --include iPodProMaxApp --include "*.resources/***" --exclude "*" "$bin/" /out/linux/$ARCH/
        strip /out/linux/$ARCH/iPodProMaxApp
        cp /out/FFmpeg/linux-$FFARCH/ffmpeg /out/linux/$ARCH/ffmpeg

        # The command-line tool: musl, fully static.
        swift sdk list --swift-sdks-path /work/sdks 2>/dev/null | grep -q static-linux \
            || swift sdk install /sdk.tar.gz --swift-sdks-path /work/sdks
        swift build -c release --swift-sdks-path /work/sdks --swift-sdk $ARCH-swift-linux-musl --product ipodpromax
        rm -rf /out/linux-cli/$ARCH && mkdir -p /out/linux-cli/$ARCH
        cp .build/$ARCH-swift-linux-musl/release/ipodpromax /out/linux-cli/$ARCH/
        strip /out/linux-cli/$ARCH/ipodpromax
        cp /out/FFmpeg/linux-$FFARCH/ffmpeg /out/linux-cli/$ARCH/ffmpeg
        echo "OK: Linux $ARCH"
    '
done
