#!/bin/bash
# Builds the ffmpeg that ships inside iPod Pro Max: a small static binary with only what syncing an
# iPod needs, from pinned sources. Nothing for the user to install (see Docs/Architecture/MediaKit.md).
#
#   Tools/FFmpeg/build.sh            # this machine's OS and architecture
#   Tools/FFmpeg/build.sh windows    # from Linux: Windows ARM64 and x64 with llvm-mingw
#
# Output: .build-work/FFmpeg/<os>-<arch>/ffmpeg[.exe] plus LICENSE.md (git-ignored; release builds
# copy it next to the app's executable, where MediaKit's FFmpeg.binaryPath() looks first).
#
# LGPL ffmpeg (no GPL parts). H.264: VideoToolbox on macOS, Media Foundation on Windows (both part
# of the OS), OpenH264 compiled from source on Linux. macOS gets arm64, x64 and a universal binary.
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
OUTPUT="$HERE/../../.build-work/FFmpeg"

FFMPEG_VERSION=8.1
FFMPEG_SHA256=b072aed6871998cce9b36e7774033105ca29e33632be5b6347f3206898e0756a
OPENH264_VERSION=2.6.0
OPENH264_SHA256=558544ad358283a7ab2930d69a9ceddf913f4a51ee9bf1bfb9e377322af81a69
LLVM_MINGW=20261020
LLVM_MINGW_SHA256_aarch64=ca16bb0f4f485876496fa46ad8d353c525eba57d0cf9e9e49ec1738fe4810151
LLVM_MINGW_SHA256_x86_64=55064b60b991a1e1e8090b8c2f84e82b22cfe5903d12c159d65064cf5e8ae335
CACHE=${IPPM_FFMPEG_CACHE:-$HERE/.cache}
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
mkdir -p "$CACHE"

fetch() { # url file sha256
    local url=$1 file=$CACHE/$2 sum=$3
    if [ ! -f "$file" ]; then curl -fsSL -o "$file.part" "$url" && mv "$file.part" "$file"; fi
    local actual
    actual=$( (command -v sha256sum >/dev/null && sha256sum "$file" || shasum -a 256 "$file") | cut -d' ' -f1)
    [ "$actual" = "$sum" ] || { echo "Checksum mismatch for $2: $actual" >&2; rm -f "$file"; exit 1; }
}

# What the sync needs, and nothing else (configure --list-* to see names).
DEMUXERS=mp3,aac,mov,flac,ogg,wav,aiff,w64,caf,asf,matroska,avi,mpegts,mpegps,flv,ac3,eac3,amr,ape,concat,ffmetadata,image2,mjpeg
DECODERS=mp1,mp1float,mp2,mp2float,mp3,mp3float,aac,aac_fixed,alac,flac,vorbis,opus,wmav1,wmav2,wmapro,wmalossless,ac3,eac3,amrnb,amrwb,ape,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_u8,pcm_alaw,pcm_mulaw,h264,hevc,mpeg4,mpeg2video,mpeg1video,msmpeg4v1,msmpeg4v2,msmpeg4v3,wmv1,wmv2,wmv3,vc1,vp8,vp9,theora,mjpeg,png,h263
ENCODERS=aac,mjpeg,pcm_s16le
MUXERS=mp4,ipod,mov,image2,null
PARSERS=aac,aac_latm,flac,mpegaudio,ac3,vorbis,opus,h264,hevc,mpeg4video,mpegvideo,vp8,vp9,vc1,mjpeg,png,h263
FILTERS=scale,format,aformat,aresample,setsar,fps,null,anull,copy,acopy
BSFS=aac_adtstoasc,extract_extradata,vp9_superframe_split
COMMON=(--disable-everything --disable-autodetect --disable-doc --disable-network --disable-ffplay --disable-ffprobe
        --disable-debug --enable-small --enable-static --disable-shared --enable-zlib
        --enable-swscale --enable-swresample --enable-avfilter
        --enable-protocol=file,pipe --enable-demuxer=$DEMUXERS --enable-decoder=$DECODERS --enable-encoder=$ENCODERS
        --enable-muxer=$MUXERS --enable-parser=$PARSERS --enable-filter=$FILTERS --enable-bsf=$BSFS)

unpack_ffmpeg() { # dest
    fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA256"
    rm -rf "$1"; mkdir -p "$1"
    tar -xJf "$CACHE/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$1" --strip-components 1
}

license() { # dest dir, extra line
    cat > "$1/LICENSE.md" <<EOF
# ffmpeg in iPod Pro Max

ffmpeg $FFMPEG_VERSION (https://ffmpeg.org), built by Tools/FFmpeg/build.sh from the unmodified
source at https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz (sha256 $FFMPEG_SHA256),
licensed under the GNU Lesser General Public License 2.1 or later
(https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html). No GPL or non-free parts are enabled.
$2
EOF
}

build_native() {
    local os arch
    case "$(uname -s)" in Darwin) os=macos ;; Linux) os=linux ;; *) echo "Unsupported OS" >&2; exit 1 ;; esac
    arch=$(uname -m); [ "$arch" = aarch64 ] && arch=arm64
    [ $os = macos ] && { build_macos; return; }
    local work=$CACHE/build-$os-$arch out=$OUTPUT/$os-$arch
    mkdir -p "$work" "$out"
    local extra=() note=""
    if true; then
        fetch "https://github.com/cisco/openh264/archive/refs/tags/v$OPENH264_VERSION.tar.gz" "openh264-$OPENH264_VERSION.tar.gz" "$OPENH264_SHA256"
        rm -rf "$work/openh264"; mkdir -p "$work/openh264"
        tar -xzf "$CACHE/openh264-$OPENH264_VERSION.tar.gz" -C "$work/openh264" --strip-components 1
        make -s -C "$work/openh264" -j"$JOBS" PREFIX="$work/prefix" install-static >/dev/null
        export PKG_CONFIG_PATH=$work/prefix/lib/pkgconfig:$work/prefix/lib64/pkgconfig
        extra=(--enable-libopenh264 --enable-encoder=libopenh264 --pkg-config-flags=--static
               --extra-ldflags="-static-libgcc -static-libstdc++" --extra-libs=-lstdc++)
        note="H.264 is encoded by OpenH264 $OPENH264_VERSION (BSD 2-Clause, https://github.com/cisco/openh264), compiled from source."
    fi
    unpack_ffmpeg "$work/ffmpeg"
    (cd "$work/ffmpeg" && ./configure --prefix="$work/prefix" "${COMMON[@]}" "${extra[@]}" >/dev/null && make -s -j"$JOBS" >/dev/null 2>&1)
    cp "$work/ffmpeg/ffmpeg" "$out/ffmpeg"
    strip "$out/ffmpeg" 2>/dev/null || true
    license "$out" "$note"
    echo "OK: $out/ffmpeg ($(du -h "$out/ffmpeg" | cut -f1))"
}

# macOS: arm64 and x86_64, then one universal binary for the universal app.
build_macos() {
    local note="H.264 is encoded by macOS's VideoToolbox."
    for arch in arm64 x64; do
        local carch=arm64; [ $arch = x64 ] && carch=x86_64
        local work=$CACHE/build-macos-$arch out=$OUTPUT/macos-$arch
        mkdir -p "$work" "$out"
        unpack_ffmpeg "$work/ffmpeg"
        local cross=(); [ "$carch" != "$(uname -m)" ] && cross=(--enable-cross-compile --arch=$carch)
        (cd "$work/ffmpeg" && ./configure --prefix="$work/prefix" "${COMMON[@]}" ${cross[@]+"${cross[@]}"} --cc="clang -arch $carch" \
            --enable-videotoolbox --enable-audiotoolbox --enable-encoder=h264_videotoolbox,aac_at --enable-decoder=alac_at \
            --extra-cflags=-mmacosx-version-min=10.15 --extra-ldflags=-mmacosx-version-min=10.15 >/dev/null \
            && make -s -j"$JOBS" >/dev/null 2>&1)
        cp "$work/ffmpeg/ffmpeg" "$out/ffmpeg"
        strip "$out/ffmpeg"
        license "$out" "$note"
        echo "OK: $out/ffmpeg ($(du -h "$out/ffmpeg" | cut -f1))"
    done
    mkdir -p "$OUTPUT/macos-universal"
    lipo -create "$OUTPUT/macos-arm64/ffmpeg" "$OUTPUT/macos-x64/ffmpeg" -output "$OUTPUT/macos-universal/ffmpeg"
    license "$OUTPUT/macos-universal" "$note"
    echo "OK: $OUTPUT/macos-universal/ffmpeg ($(du -h "$OUTPUT/macos-universal/ffmpeg" | cut -f1))"
}

build_windows() {
    local toolchain=$CACHE/llvm-mingw-$LLVM_MINGW
    if [ ! -d "$toolchain" ]; then
        # The cross-compiler (llvm-mingw, Apache 2.0 with LLVM exceptions), pinned like the sources.
        local host=x86_64; [ "$(uname -m)" = aarch64 ] && host=aarch64
        local sum=LLVM_MINGW_SHA256_$host
        local archive=llvm-mingw-$LLVM_MINGW-ucrt-ubuntu-22.04-$host.tar.xz
        fetch "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW/$archive" "$archive" "${!sum}"
        mkdir -p "$toolchain" && tar -xJf "$CACHE/$archive" -C "$toolchain" --strip-components 1
    fi
    export PATH=$toolchain/bin:$PATH
    for arch in arm64 x64; do
        local triple=aarch64-w64-mingw32 farch=aarch64
        [ $arch = x64 ] && triple=x86_64-w64-mingw32 farch=x86_64
        local work=$CACHE/build-windows-$arch out=$OUTPUT/windows-$arch
        mkdir -p "$work" "$out"
        unpack_ffmpeg "$work/ffmpeg"
        (cd "$work/ffmpeg" && ./configure --prefix="$work/prefix" --target-os=mingw32 --arch=$farch --cross-prefix=$triple- \
            --enable-cross-compile --cc=$triple-clang --cxx=$triple-clang++ "${COMMON[@]}" --disable-zlib \
            --enable-mediafoundation --enable-d3d11va --enable-encoder=h264_mf,aac_mf --extra-ldflags=-static >/dev/null && make -s -j"$JOBS" >/dev/null)
        cp "$work/ffmpeg/ffmpeg.exe" "$out/ffmpeg.exe"
        $triple-strip "$out/ffmpeg.exe" 2>/dev/null || true
        license "$out" "H.264 and AAC can be encoded by Windows's Media Foundation; the static C++ runtime is from llvm-mingw (Apache 2.0 with LLVM exceptions)."
        echo "OK: $out/ffmpeg.exe ($(du -h "$out/ffmpeg.exe" | cut -f1))"
    done
}

case "${1:-native}" in
native) build_native ;;
windows) build_windows ;;
*) echo "usage: build.sh [windows]" >&2; exit 2 ;;
esac
