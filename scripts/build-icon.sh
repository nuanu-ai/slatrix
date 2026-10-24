#!/bin/bash
# Rebuilds Config/Slatrix.icns from the SVG masters. Needs rsvg-convert (brew install librsvg).
# The 16 and 32 pt slots use the simplified artwork, which stays legible at that size.
set -euo pipefail
cd "$(dirname "$0")/../Config"
set_dir=$(mktemp -d)/Slatrix.iconset
mkdir -p "$set_dir"
render() { rsvg-convert -w "$2" -h "$2" "AppIcon/$1.svg" -o "$set_dir/$3"; }
render Slatrix-small 16 icon_16x16.png
render Slatrix-small 32 icon_16x16@2x.png
render Slatrix-small 32 icon_32x32.png
render Slatrix 64 icon_32x32@2x.png
for size in 128 256 512; do
    render Slatrix "$size" "icon_${size}x${size}.png"
    render Slatrix $((size * 2)) "icon_${size}x${size}@2x.png"
done
iconutil -c icns "$set_dir" -o Slatrix.icns
