#!/bin/bash
# Builds the prototype for every OS from the Mac, driving the Parallels VMs with prlctl.
#
#   ./build.sh                 # mac + linux + windows
#   ./build.sh mac linux       # only some targets
#   ./build.sh --setup windows # first run: also install the toolchains in the VM(s)
#   ./build.sh --run mac       # open the Mac app once built
#
# Output: dist/mac/iPod Pro Max Proto.app, dist/linux/iPodProMaxProto, dist/windows/iPodProMaxProto.exe
# The VMs read the sources and write dist/ through the Mac home folder shared by Parallels, and
# compile in a local copy (~/dev/swiftcrossui, C:\dev\swiftcrossui) because building on the share is slow.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(pwd)

LINUX_VM=${LINUX_VM:-"Fedora Linux"}
WINDOWS_VM=${WINDOWS_VM:-"Windows 11"}
SETUP=0; RUN=0; TARGETS=()
for arg in "$@"; do
    case $arg in
        --setup) SETUP=1 ;;
        --run) RUN=1 ;;
        mac|linux|windows) TARGETS+=("$arg") ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(mac linux windows)

case $ROOT in
    "$HOME"/*) REL=${ROOT#"$HOME"/} ;;
    *) echo "The prototype must live under $HOME so the VMs can see it." >&2; exit 1 ;;
esac
LINUX_SRC="/media/psf/Home/$REL"
WINDOWS_SRC='\\Mac\Home\'"${REL//\//\\}"

build_mac() {
    swift build -c release
    local bin app
    bin=$(swift build -c release --show-bin-path)
    app="dist/mac/iPod Pro Max Proto.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    cp "$bin/iPodProMaxProto" "$app/Contents/MacOS/"
    cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>iPodProMaxProto</string>
    <key>CFBundleIdentifier</key><string>com.ipodpromax.proto</string>
    <key>CFBundleName</key><string>iPod Pro Max Proto</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
    codesign --force --sign - "$app"
    echo "OK: $ROOT/$app"
    [ $RUN -eq 1 ] && open "$app"
    return 0
}

# Starts the VM if needed and waits until Parallels Tools accept commands in a user session.
# The wait is bounded and only exists for this build.
ensure_vm() {
    local vm=$1 probe=$2
    if ! prlctl status "$vm" | grep -q running; then
        echo "Starting VM $vm…"
        prlctl start "$vm" >/dev/null
    fi
    for _ in $(seq 1 60); do
        prlctl exec "$vm" --current-user $probe >/dev/null 2>&1 && return 0
        sleep 3
    done
    echo "VM $vm does not answer: open it and log in to your session, then run again." >&2
    return 1
}

build_linux() {
    if prlctl list -i "$LINUX_VM" | grep -q "Host Shared Folders: (-)"; then
        echo "Sharing the Mac home folder with $LINUX_VM (/media/psf/Home)…"
        prlctl set "$LINUX_VM" --shf-host on --shf-host-defined home >/dev/null
    fi
    ensure_vm "$LINUX_VM" true
    if [ $SETUP -eq 1 ]; then
        prlctl exec "$LINUX_VM" bash "$LINUX_SRC/scripts/build-linux.sh" deps
    fi
    prlctl exec "$LINUX_VM" --current-user bash "$LINUX_SRC/scripts/build-linux.sh" build "$LINUX_SRC"
}

build_windows() {
    ensure_vm "$WINDOWS_VM" "cmd /c exit 0"
    local setup=()
    [ $SETUP -eq 1 ] && setup=(-Setup)
    prlctl exec "$WINDOWS_VM" --current-user powershell.exe -NoProfile -ExecutionPolicy Bypass \
        -File "$WINDOWS_SRC\\scripts\\build-windows.ps1" -Source "$WINDOWS_SRC" ${setup[@]+"${setup[@]}"}
}

# The Mac builds first (it is the quickest feedback), then both VMs build at the same time.
pids=(); names=()
for t in "${TARGETS[@]}"; do
    case $t in
        mac) build_mac 2>&1 | sed -u 's/^/[mac] /' ;;
        *)
            mkdir -p dist
            ( set -o pipefail; "build_$t" 2>&1 | sed -u "s/^/[$t] /" | tee "dist/$t.log" ) &
            pids+=($!); names+=("$t") ;;
    esac
done
status=0
for ((i = 0; i < ${#names[@]}; i++)); do
    if wait "${pids[$i]}"; then echo "[${names[$i]}] OK"; else echo "[${names[$i]}] FAILED (dist/${names[$i]}.log)"; status=1; fi
done
exit $status
