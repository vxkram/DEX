#!/bin/sh
# Vendors the libwebp encoder and muxer into Packages/DexCore/Sources/CWebP.
# Re-run to update: bump VERSION and SHA256 (from a signature-verified download).
set -eu

VERSION=1.6.0
SHA256=e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
URL="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$VERSION.tar.gz"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$ROOT/Packages/DexCore/Sources/CWebP"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

curl -sSfL "$URL" -o "$WORK/libwebp.tar.gz"
echo "$SHA256  $WORK/libwebp.tar.gz" | shasum -a 256 -c -
tar xzf "$WORK/libwebp.tar.gz" -C "$WORK"
SRC="$WORK/libwebp-$VERSION"

rm -rf "$DEST/src" "$DEST/sharpyuv"
mkdir -p "$DEST/src"
# Encoder, muxer and their shared code. The decoder is not needed:
# ImageIO decodes WebP.
for dir in src/enc src/dsp src/utils src/mux src/dec src/webp sharpyuv; do
    mkdir -p "$DEST/$dir"
    find "$SRC/$dir" -maxdepth 1 \( -name '*.c' -o -name '*.h' \) -exec cp {} "$DEST/$dir/" \;
done
cp "$SRC/COPYING" "$DEST/COPYING"
cp "$SRC/PATENTS" "$DEST/PATENTS"
echo "libwebp $VERSION ($SHA256), vendored by scripts/vendor-libwebp.sh" > "$DEST/VERSION"
echo "Vendored libwebp $VERSION into $DEST"
