#!/usr/bin/env bash
# Re-vendors the native decoder sources into third_party/.
#
# Usage: tool/update_third_party.sh
#
# Bump the versions below, run the script, then rebuild and run the tests.
set -euo pipefail

LIBAVIF_VERSION="v1.4.2"
DAV1D_VERSION="1.5.4"
# The libyuv revision pinned by libavif's ext/libyuv.cmd for LIBAVIF_VERSION.
LIBYUV_REVISION="644251f252a84bf8ce91ff0aca86a9b16b069ab8"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/third_party"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git -c advice.detachedHead=false clone -q --depth 1 -b "$LIBAVIF_VERSION" \
  https://github.com/AOMediaCodec/libavif.git "$WORK/libavif"
git -c advice.detachedHead=false clone -q --depth 1 -b "$DAV1D_VERSION" \
  https://code.videolan.org/videolan/dav1d.git "$WORK/dav1d"
git -c advice.detachedHead=false clone -q https://chromium.googlesource.com/libyuv/libyuv "$WORK/libyuv"
git -C "$WORK/libyuv" -c advice.detachedHead=false checkout -q "$LIBYUV_REVISION"

rm -rf "$DEST/libavif" "$DEST/dav1d" "$DEST/libyuv"
mkdir -p "$DEST/libavif/src" "$DEST/dav1d" "$DEST/libyuv/source"

# libavif: decoder-relevant sources only (dav1d is the only AV1 codec).
cp "$WORK/libavif/LICENSE" "$DEST/libavif/"
cp -r "$WORK/libavif/include" "$DEST/libavif/"
rm -f "$DEST/libavif/include/avif/avif_cxx.h"
for f in "$WORK"/libavif/src/*.c; do
  case "$(basename "$f")" in
    codec_aom.c | codec_avm.c | codec_libgav1.c | codec_rav1e.c | codec_svt.c) ;;
    *) cp "$f" "$DEST/libavif/src/" ;;
  esac
done

# dav1d: library sources for the architectures Flutter targets.
cp "$WORK/dav1d/COPYING" "$WORK/dav1d/NEWS" "$DEST/dav1d/"
mkdir -p "$DEST/dav1d/include"
cp -r "$WORK/dav1d/include/common" "$WORK/dav1d/include/compat" \
  "$WORK/dav1d/include/dav1d" "$DEST/dav1d/include/"
rm -f "$DEST/dav1d/include/dav1d/meson.build" "$DEST/dav1d/include/compat/getopt.h"
cp -r "$WORK/dav1d/src" "$DEST/dav1d/"
rm -rf "$DEST/dav1d/src/loongarch" "$DEST/dav1d/src/ppc" \
  "$DEST/dav1d/src/meson.build" "$DEST/dav1d/src/dav1d.rc.in"

# libyuv: everything except JPEG support, tests and build files.
cp "$WORK/libyuv/LICENSE" "$WORK/libyuv/PATENTS" "$DEST/libyuv/"
cp -r "$WORK/libyuv/include" "$DEST/libyuv/"
for f in "$WORK"/libyuv/source/*.cc; do
  case "$(basename "$f")" in
    convert_jpeg.cc | mjpeg_decoder.cc | mjpeg_validate.cc) ;;
    *) cp "$f" "$DEST/libyuv/source/" ;;
  esac
done

cat > "$DEST/VERSIONS" <<VERSIONS
libavif ${LIBAVIF_VERSION}
dav1d ${DAV1D_VERSION}
libyuv ${LIBYUV_REVISION}
VERSIONS

echo "Vendored libavif ${LIBAVIF_VERSION}, dav1d ${DAV1D_VERSION}, libyuv ${LIBYUV_REVISION}."
