#!/bin/bash
# Builds the application for every OS from the Mac, driving the Parallels VMs with prlctl.
#
#   ./build.sh                 # mac + linux + windows
#   ./build.sh mac linux       # only some targets
#   ./build.sh --setup windows # force a toolchain install in the VM(s) (done automatically if missing)
#   ./build.sh --run linux     # open the app once built (on the Mac, or in the VM's session)
#
# Output: Build/mac/iPod Pro Max.app, Build/linux/iPodProMaxApp, Build/windows/iPodProMaxApp.exe
# The VMs read the sources and write Build/ through the Mac home folder shared by Parallels, and
# compile in a local copy (~/dev/swiftcrossui, C:\dev\swiftcrossui) because building on the share is slow.
set -euo pipefail
cd "$(dirname "$0")/../.."
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
    *) echo "The repository must live under $HOME so the VMs can see it." >&2; exit 1 ;;
esac
LINUX_SRC="/media/psf/Home/$REL"
# The app icon for each platform, from iPod Pro Max/Resources/AppIcon.appiconset (Build/icons, read by the VMs too).
Tools/Build/make-icons.sh
WINDOWS_SRC='\\Mac\Home\'"${REL//\//\\}"

build_mac() {
    swift package resolve
    Tools/Build/patch-dependencies.sh .build
    swift build -c release --product iPodProMaxApp
    local bin app
    bin=$(swift build -c release --show-bin-path)
    app="Build/mac/iPod Pro Max.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$bin/iPodProMaxApp" "$app/Contents/MacOS/"
    # The app's own ffmpeg (Tools/FFmpeg/build.sh), next to the executable where MediaKit looks.
    local ffmpeg="$ROOT/Build/FFmpeg/macos-universal/ffmpeg"
    if [ -x "$ffmpeg" ]; then cp "$ffmpeg" "$app/Contents/MacOS/"; else echo "warning: ffmpeg not built (Tools/FFmpeg/build.sh)" >&2; fi
    cp Build/icons/AppIcon.icns "$app/Contents/Resources/"
    cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>iPodProMaxApp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.ipodpromax.proto</string>
    <key>CFBundleName</key><string>iPod Pro Max</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
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
        echo "Starting VM ${vm}…"
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
    local setup=$SETUP
    # The test lives in the script: prlctl exec splits quoted arguments on spaces.
    if [ $setup -eq 0 ] && ! prlctl exec "$LINUX_VM" --current-user \
        bash "$LINUX_SRC/Tools/Build/build-linux.sh" check >/dev/null 2>&1; then
        echo "First build in $LINUX_VM: installing GTK 4 and Swift (a few minutes)…"
        setup=1
    fi
    if [ $setup -eq 1 ]; then
        prlctl exec "$LINUX_VM" bash "$LINUX_SRC/Tools/Build/build-linux.sh" deps
    fi
    prlctl exec "$LINUX_VM" --current-user bash "$LINUX_SRC/Tools/Build/build-linux.sh" build "$LINUX_SRC"
    if [ $RUN -eq 1 ]; then
        prlctl exec "$LINUX_VM" --current-user bash "$LINUX_SRC/Tools/Build/build-linux.sh" run
        show_vm
    fi
    return 0
}

build_windows() {
    ensure_vm "$WINDOWS_VM" "cmd /c exit 0"
    local flags=()
    if [ $SETUP -eq 1 ] || ! prlctl exec "$WINDOWS_VM" --current-user cmd /c where swift >/dev/null 2>&1 \
        || ! prlctl exec "$WINDOWS_VM" --current-user cmd /c where git >/dev/null 2>&1; then
        echo "First build in $WINDOWS_VM: installing Visual Studio, Swift and WinUI (long; approve the admin prompts in the VM)…"
        flags+=(-Setup)
    fi
    [ $RUN -eq 1 ] && flags+=(-Run)
    # prlctl exec drops sessions that last as long as a first Windows build (it once reported
    # failure while swift-frontend kept compiling), so the build runs detached in the VM and
    # writes its log and exit code to Build/; this waits for the exit code, two hours at most.
    local out="$ROOT/Build/windows-vm.log" status="$ROOT/Build/windows-vm.exit"
    rm -f "$out" "$status" "$status.tmp"
    local args="'-NoProfile','-ExecutionPolicy','Bypass','-File','$WINDOWS_SRC\\Tools\\Build\\build-windows-detached.ps1','-Source','$WINDOWS_SRC'"
    for f in ${flags[@]+"${flags[@]}"}; do args+=",'$f'"; done
    prlctl exec "$WINDOWS_VM" --current-user powershell.exe -NoProfile -Command \
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "$args"
    local shown=0
    for _ in $(seq 1 1440); do
        if [ -f "$out" ]; then
            local lines
            lines=$(wc -l < "$out")
            [ "$lines" -gt "$shown" ] && tail -n +"$((shown + 1))" "$out" | LC_ALL=C tr -cd '\11\12\15\40-\176' && shown=$lines
        fi
        [ -f "$status" ] && break
        sleep 5
    done
    # Lines written between the last pass and the exit file.
    [ -f "$out" ] && tail -n +"$((shown + 1))" "$out" | LC_ALL=C tr -cd '\11\12\15\40-\176'
    [ -f "$status" ] || { echo "Timed out waiting for the Windows build." >&2; return 1; }
    [ "$(tr -cd '0-9' < "$status")" = "0" ] || return 1
    [ $RUN -eq 1 ] && show_vm
    return 0
}

# Brings Parallels to the front so the VM window with the app just launched is visible.
show_vm() {
    open -a "Parallels Desktop" || true
}

# The Mac builds first (it is the quickest feedback), then both VMs build at the same time.
pids=(); names=()
for t in "${TARGETS[@]}"; do
    case $t in
        mac) build_mac 2>&1 | sed -u 's/^/[mac] /' ;;
        *)
            mkdir -p Build
            ( set -o pipefail; "build_$t" 2>&1 | sed -u "s/^/[$t] /" | tee "Build/$t.log" ) &
            pids+=($!); names+=("$t") ;;
    esac
done
status=0
for ((i = 0; i < ${#names[@]}; i++)); do
    if wait "${pids[$i]}"; then echo "[${names[$i]}] OK"; else echo "[${names[$i]}] FAILED (Build/${names[$i]}.log)"; status=1; fi
done
exit $status
