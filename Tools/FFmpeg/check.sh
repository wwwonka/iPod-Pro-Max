#!/bin/bash
# Checks an ffmpeg built by build.sh against every job MediaKit gives it, on generated samples.
#   Tools/FFmpeg/check.sh <ffmpeg> <scratch dir> <a FLAC file> <a video file>
set -euo pipefail
FF=$1; W=$2; FLAC=$3; VIDEO=$4
rm -rf "$W"; mkdir -p "$W"
run() { echo "· $1"; shift; "$FF" -nostdin -y -v error "$@"; }

run "FLAC to AAC" -i "$FLAC" -map 0:a:0 -map_metadata 0 -c:a aac -b:a 256k -movflags +faststart "$W/song.m4a"
enc=$("$FF" -hide_banner -encoders 2>/dev/null | awk '$1 ~ /^V/ {print $2}' | grep -E "h264|openh264" | head -1)
echo "· H.264 encoder: ${enc:-none}"
scale="scale='min(320,iw)':'min(240,ih)':force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1"
echo "· video for the iPod (with -progress)"; run "" -nostats -progress pipe:1 -i "$VIDEO" -map 0:v:0 -map "0:a:0?" -vf "$scale" -r 30 \
    -pix_fmt yuv420p -c:v "$enc" -b:v 700k -c:a aac -b:a 128k -ac 2 -ar 44100 -movflags +faststart -f mp4 "$W/clip.m4v" >/dev/null
run "poster frame" -ss 0 -i "$VIDEO" -frames:v 1 -vf "scale='min(640,iw)':-2" -q:v 3 "$W/poster.jpg"
printf "file '%s'\nfile '%s'\n" "$W/song.m4a" "$W/song.m4a" > "$W/list.txt"
printf ";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=One\n" > "$W/chapters.txt"
run "audiobook: concat" -f concat -safe 0 -i "$W/list.txt" -c copy "$W/book-raw.m4a"
run "audiobook: chapters" -i "$W/book-raw.m4a" -i "$W/chapters.txt" -map_metadata 1 -codec copy "$W/book.m4b"
{ "$FF" -hide_banner -i "$W/clip.m4v" 2>&1 || true; } | grep -E "Video:|Audio:" | sed "s/^ */  /"
{ "$FF" -hide_banner -i "$W/book.m4b" 2>&1 || true; } | grep -E "Chapter #" | sed "s/^ */  /"
ls -la "$W" | awk 'NR>1 {print "  " $NF, $5}'
echo "OK"
