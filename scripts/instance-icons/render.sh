#!/bin/bash
# Render the built-in instance icons (SVG, from Prism Launcher) to PNGs the app ships in
# Natives/resources/InstanceIcons/. SVGs are vectors, so any size is sharp: change SIZE to re-render.
# Usage: scripts/instance-icons/render.sh [size-in-pixels]      (default 512)
# Needs: rsvg-convert (librsvg).
set -euo pipefail

SIZE="${1:-512}"
command -v rsvg-convert >/dev/null || { echo "Missing tool: rsvg-convert (install librsvg)" >&2; exit 2; }
case "$SIZE" in ''|*[!0-9]*) echo "Size must be a whole number of pixels" >&2; exit 2;; esac

HERE="$(cd "$(dirname "$0")" && pwd -P)"
OUT="$HERE/../../Natives/resources/InstanceIcons"
mkdir -p "$OUT"

count=0
for svg in "$HERE"/src/*.svg; do
    name="$(basename "$svg" .svg)"
    rsvg-convert -w "$SIZE" -h "$SIZE" "$svg" -o "$OUT/$name.png"
    count=$((count + 1))
done
echo "Rendered $count icons at ${SIZE}x${SIZE} into $OUT"
