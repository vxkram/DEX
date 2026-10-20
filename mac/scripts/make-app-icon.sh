#!/bin/sh
# Builds the app icon set from one 1024×1024 PNG.
# Usage: scripts/make-app-icon.sh [path/to/icon-1024.png]   (default: design/AppIcon-1024.png)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# The icon master is shared with the Windows app, at the repo root.
MASTER="$ROOT/../design/AppIcon-1024.png"
SOURCE=${1:-"$MASTER"}
SET="$ROOT/App/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$SET"
[ "$SOURCE" = "$MASTER" ] || cp "$SOURCE" "$MASTER"

images=""
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        pixels=$((size * scale))
        name="icon_${size}x${size}@${scale}x.png"
        sips -z $pixels $pixels "$SOURCE" --out "$SET/$name" >/dev/null
        images="$images{\"idiom\":\"mac\",\"size\":\"${size}x${size}\",\"scale\":\"${scale}x\",\"filename\":\"$name\"},"
    done
done
printf '{"images":[%s],"info":{"version":1,"author":"xcode"}}\n' "${images%,}" > "$SET/Contents.json"
echo "App icon updated from $SOURCE"
