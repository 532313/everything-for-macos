#!/bin/bash
# Regenerates the media fixtures used to verify thumbnails and the icon views
# (see README: 视图模式 / UI 冒烟测试). Requires ffmpeg.
#
#   ./Tools/make_testmedia.sh [output-dir]      # default: Tools/testmedia
#   EVERYTHING_UI_SMOKE=/tmp/ui EVERYTHING_UI_SMOKE_QUERY='path:testmedia' \
#     ./build/Everything.app/Contents/MacOS/Everything
set -euo pipefail
OUT="${1:-$(cd "$(dirname "$0")" && pwd)/testmedia}"
command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)"; exit 1; }
mkdir -p "$OUT"

ffmpeg -v error -f lavfi -i testsrc2=size=640x360:rate=25 -t 2 -pix_fmt yuv420p "$OUT/clip-h264.mp4" -y
ffmpeg -v error -f lavfi -i testsrc2=size=640x360:rate=25 -t 2 -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p "$OUT/clip-hevc.mp4" -y
ffmpeg -v error -f lavfi -i smptebars=size=480x270:rate=25 -t 2 -pix_fmt yuv420p "$OUT/clip-bars.mov" -y
ffmpeg -v error -f lavfi -i testsrc2=size=270x480:rate=25 -t 2 -pix_fmt yuv420p "$OUT/clip-portrait.mp4" -y
ffmpeg -v error -f lavfi -i testsrc2=size=400x400:rate=1 -frames:v 1 "$OUT/photo.png" -y
ls -1 "$OUT"
