#!/bin/sh
# Vendors the LAME MP3 encoder library into Packages/Lame/Sources/CLame.
# Re-run to update: bump VERSION and SHA256 (from the SourceForge release).
#
# LAME is LGPL-2.0-or-later, so it is built as its own dynamic library
# (Packages/Lame, product "Lame") and shipped as a separate framework in
# the app, never linked into DEX's own binary. See docs/adr/0005-audio.md.
set -eu

VERSION=4.0
SHA256=3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb
URL="https://downloads.sourceforge.net/project/lame/lame/$VERSION/lame-$VERSION.tar.gz"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$ROOT/Packages/Lame/Sources/CLame"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

curl -sSfL "$URL" -o "$WORK/lame.tar.gz"
echo "$SHA256  $WORK/lame.tar.gz" | shasum -a 256 -c -
tar xzf "$WORK/lame.tar.gz" -C "$WORK"
SRC="$WORK/lame-$VERSION"

rm -rf "$DEST"
mkdir -p "$DEST/include"
# The encoder only: DEX decodes MP3 with AVFoundation, so mpglib and
# the x86 SIMD routines (vector/, i386/) are left out.
find "$SRC/libmp3lame" -maxdepth 1 \( -name '*.c' -o -name '*.h' \) ! -name 'mpglib_interface.c' -exec cp {} "$DEST/" \;
# fft.c and quantize.c include this header unconditionally; its SSE code
# is never compiled on arm64.
mkdir -p "$DEST/vector"
cp "$SRC/libmp3lame/vector/lame_intrin.h" "$DEST/vector/"
cp "$SRC/include/lame.h" "$DEST/include/lame.h"
cp "$SRC/COPYING" "$DEST/COPYING"
cp "$SRC/LICENSE" "$DEST/LICENSE"

# What LAME's configure produces on Apple Silicon macOS, without the
# frontend or decoder (configure itself needs pkg-config and autotools).
cat > "$DEST/config.h" <<'EOF'
#ifndef LAME_CONFIG_H
#define LAME_CONFIG_H
#define HAVE_ALLOCA 1
#define HAVE_ALLOCA_H 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_INT16_T 1
#define HAVE_INT32_T 1
#define A_INT32_T int
#define HAVE_INT64_T 1
#define A_INT64_T long
#define HAVE_INT8_T 1
#define HAVE_INTTYPES_H 1
#define HAVE_LIMITS_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UINT16_T 1
#define HAVE_UINT32_T 1
#define A_UINT32_T unsigned int
#define HAVE_UINT64_T 1
#define A_UINT64_T unsigned long
#define HAVE_UINT8_T 1
#define HAVE_UNISTD_H 1
#define LAME_LIBRARY_BUILD 1
#define PACKAGE "lame"
#define PACKAGE_VERSION "4.0"
#define SIZEOF_DOUBLE 8
#define SIZEOF_FLOAT 4
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_LONG_LONG 8
#define SIZEOF_SHORT 2
#define SIZEOF_UNSIGNED_INT 4
#define SIZEOF_UNSIGNED_LONG 8
#define SIZEOF_UNSIGNED_LONG_LONG 8
#define SIZEOF_UNSIGNED_SHORT 2
#define STDC_HEADERS 1
#define TAKEHIRO_IEEE754_HACK 0
#define VERSION "4.0"
#define _DARWIN_C_SOURCE 1
typedef float ieee754_float32_t;
typedef double ieee754_float64_t;
typedef long double ieee854_float80_t;
#endif
EOF

echo "LAME $VERSION ($SHA256), vendored by scripts/vendor-lame.sh" > "$DEST/VERSION"
# Shown in the app's About window.
mkdir -p "$ROOT/App/Resources/Licenses"
cp "$SRC/COPYING" "$ROOT/App/Resources/Licenses/LAME-COPYING.txt"
echo "Vendored LAME $VERSION into $DEST"
