#!/bin/bash
# Builds iPod Pro Max for every OS from the Mac, then lays Build/ out as the root of an iPod
# (Tools/Build/assemble-ipod.sh). Windows and Linux are built in the Parallels VMs, driven by prlctl.
#
#   ./build.sh                 # mac + linux + windows, then Build/
#   ./build.sh mac linux       # only some targets (Build/ keeps what the others built last)
#   ./build.sh --setup windows # force a toolchain install in the VM(s) (done automatically if missing)
#   ./build.sh --run mac       # open the app once built, through Build/LAUNCHER (or in the VM's session)
#   ./build.sh --clean         # also start Build/iPod_Control and Persistent Data over
#
# Each OS's build goes to .build-work/<os>/ first (with ffmpeg, the icons and the logs); Build/ only
# holds what an iPod would. The VMs read the sources and write .build-work/ through the Mac home
# folder shared by Parallels, and compile in a local copy (~/dev/swiftcrossui, C:\dev\swiftcrossui)
# because building on the share is slow.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
WORK="$ROOT/.build-work"

LINUX_VM=${LINUX_VM:-"Fedora Linux"}
WINDOWS_VM=${WINDOWS_VM:-"Windows 11"}
SETUP=0; RUN=0; CLEAN=(); TARGETS=()
for arg in "$@"; do
    case $arg in
        --setup) SETUP=1 ;;
        --run) RUN=1 ;;
        --clean) CLEAN=(--clean) ;;
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
mkdir -p "$WORK"
# The app icon for each platform, from iPod Pro Max/Resources/AppIcon.appiconset (.build-work/icons, read by the VMs too).
Tools/Build/make-icons.sh
WINDOWS_SRC='\\Mac\Home\'"${REL//\//\\}"

# Universal (arm64 + x86_64) app and command-line tool for macOS 10.15.4 and later. One build per
# architecture, then lipo: SwiftPM's multi-architecture build can't build SwiftCrossUI's macros.
build_mac() {
    # The two architectures build at the same time (a release build is mostly single-threaded):
    # x86_64 in its own scratch folder, since SwiftPM locks .build while it builds.
    swift package resolve
    Tools/Build/patch-dependencies.sh .build
    local x86=.build-x86_64
    swift package resolve --scratch-path "$x86"
    Tools/Build/patch-dependencies.sh "$x86"
    build_arch() { # <arch> <scratch>
        local product
        for product in iPodProMaxApp ipodpromax; do
            swift build -c release --scratch-path "$2" --triple "$1-apple-macosx10.15.4" --product "$product" 2>&1 | sed -u "s/^/[mac $1] /"
            [ "${PIPESTATUS[0]}" -eq 0 ] || return 1
        done
    }
    build_arch arm64 .build & local arm_pid=$!
    build_arch x86_64 "$x86" & local x86_pid=$!
    wait "$arm_pid" || { wait "$x86_pid" || true; return 1; }
    wait "$x86_pid" || return 1
    universal() { # <product> <output>
        lipo -create ".build/arm64-apple-macosx/release/$1" "$x86/x86_64-apple-macosx/release/$1" -output "$2"
    }
    # Swift concurrency is in macOS 12 and later; before that it comes with the app (found through
    # the executables' @loader_path rpath).
    local concurrency
    concurrency="$(dirname "$(xcrun --find swift)")/../lib/swift-5.5/macosx/libswift_Concurrency.dylib"
    # The app's own ffmpeg (Tools/FFmpeg/build.sh), next to each executable where MediaKit looks.
    local ffmpeg="$WORK/FFmpeg/macos-universal/ffmpeg"
    [ -x "$ffmpeg" ] || Tools/FFmpeg/build.sh || echo "warning: ffmpeg couldn't be built (Tools/FFmpeg/build.sh)" >&2
    extras() { # <folder>: the concurrency runtime and ffmpeg, signed
        cp "$concurrency" "$1/"
        [ -x "$ffmpeg" ] && cp "$ffmpeg" "$1/"
        codesign --force --sign - "$1"/*.dylib
        [ -f "$1/ffmpeg" ] && codesign --force --sign - "$1/ffmpeg"
        return 0
    }

    local cli="$WORK/mac/cli"
    rm -rf "$cli"
    mkdir -p "$cli"
    universal ipodpromax "$cli/ipodpromax"
    extras "$cli"
    codesign --force --sign - "$cli/ipodpromax"

    local app="$WORK/mac/app/iPod Pro Max.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    universal iPodProMaxApp "$app/Contents/MacOS/iPodProMaxApp"
    extras "$app/Contents/MacOS"
    cp "$WORK/icons/AppIcon.icns" "$app/Contents/Resources/"
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
    <key>LSMinimumSystemVersion</key><string>10.15.4</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPhotoLibraryUsageDescription</key><string>iPod Pro Max copies the albums you choose from Photos to your iPod.</string>
</dict>
</plist>
EOF
    codesign --force --sign - "$app"
    echo "OK: $app, $cli"
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

# Linux builds in Docker on the Mac (x86_64 and aarch64). IPPM_LINUX_BUILD=vm builds the app in the
# Fedora VM instead, as before (its own architecture only, no command-line tool).
build_linux() {
    if [ "${IPPM_LINUX_BUILD:-docker}" = vm ]; then build_linux_vm; return; fi
    Tools/Build/build-linux-docker.sh
    [ $RUN -eq 1 ] && echo "To try it: in a Linux session, sh <Build>/LAUNCHER.bat (the VM sees Build/ in /media/psf/Home)."
    return 0
}

build_linux_vm() {
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
    # writes its log and exit code to .build-work/; this waits for the exit code, two hours at most.
    local out="$WORK/windows-vm.log" status="$WORK/windows-vm.exit"
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

# Linux and Windows start first, in the background (Docker and the VM do the work); the Mac builds
# meanwhile, so the total is the slowest of the three rather than their sum.
pids=(); names=()
for t in linux windows; do
    [[ " ${TARGETS[*]} " == *" $t "* ]] || continue
    ( set -o pipefail; "build_$t" 2>&1 | sed -u "s/^/[$t] /" | tee "$WORK/$t.log" ) &
    pids+=($!); names+=("$t")
done
if [[ " ${TARGETS[*]} " == *" mac "* ]]; then
    build_mac 2>&1 | sed -u 's/^/[mac] /' || status_mac=1
fi
status=${status_mac:-0}
for ((i = 0; i < ${#names[@]}; i++)); do
    if wait "${pids[$i]}"; then echo "[${names[$i]}] OK"; else echo "[${names[$i]}] FAILED (.build-work/${names[$i]}.log)"; status=1; fi
done

# Build/ as an iPod root, with whatever each OS built (now or last time).
Tools/Build/assemble-ipod.sh ${CLEAN[@]+"${CLEAN[@]}"}
if [ $RUN -eq 1 ] && [[ " ${TARGETS[*]} " == *" mac "* ]]; then
    sh Build/LAUNCHER.bat
fi
exit $status
