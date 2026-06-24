#!/bin/bash
# Regenerate AppIcon.icns from the master PNG.
# Usage: swift tools/make_icon.swift && ./tools/make_icns.sh
set -euo pipefail
cd "$(dirname "$0")/.."

M=tools/icon_master.png
[ -f "$M" ] || { echo "Missing $M — run: swift tools/make_icon.swift"; exit 1; }

rm -rf tools/Solo.iconset && mkdir -p tools/Solo.iconset
gen() { sips -z "$2" "$2" "$M" --out "tools/Solo.iconset/$1" >/dev/null; }
gen icon_16x16.png 16
gen icon_16x16@2x.png 32
gen icon_32x32.png 32
gen icon_32x32@2x.png 64
gen icon_128x128.png 128
gen icon_128x128@2x.png 256
gen icon_256x256.png 256
gen icon_256x256@2x.png 512
gen icon_512x512.png 512
gen icon_512x512@2x.png 1024
iconutil -c icns -o AppIcon.icns tools/Solo.iconset
echo "==> Wrote AppIcon.icns"
