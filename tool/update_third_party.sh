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

# Only the files that hook/src/sources.dart compiles (or that they include).
LIBAVIF_SOURCES=(
  alpha.c avif.c codec_dav1d.c colr.c colrconvert.c diag.c exif.c gainmap.c
  io.c mem.c obu.c properties.c rawdata.c read.c reformat.c
  reformat_libsharpyuv.c reformat_libyuv.c sampletransform.c scale.c stream.c
  utils.c
)
LIBYUV_SOURCES=(
  convert.cc convert_argb.cc convert_from_argb.cc cpu_id.cc
  planar_functions.cc rotate.cc rotate_any.cc rotate_argb.cc rotate_common.cc
  rotate_gcc.cc rotate_neon.cc rotate_neon64.cc row_any.cc row_common.cc
  row_gcc.cc row_neon.cc row_neon64.cc row_sve.cc row_win.cc scale.cc
  scale_any.cc scale_argb.cc scale_common.cc scale_gcc.cc scale_neon.cc
  scale_neon64.cc scale_uv.cc scale_win.cc
)

cp "$WORK/libavif/LICENSE" "$DEST/libavif/"
cp -r "$WORK/libavif/include" "$DEST/libavif/"
rm -f "$DEST/libavif/include/avif/avif_cxx.h"
for f in "${LIBAVIF_SOURCES[@]}"; do
  cp "$WORK/libavif/src/$f" "$DEST/libavif/src/"
done

cp "$WORK/dav1d/COPYING" "$DEST/dav1d/"
mkdir -p "$DEST/dav1d/include/compat"
cp -r "$WORK/dav1d/include/common" "$WORK/dav1d/include/dav1d" "$DEST/dav1d/include/"
cp -r "$WORK/dav1d/include/compat/msvc" "$DEST/dav1d/include/compat/"
rm -f "$DEST/dav1d/include/dav1d/meson.build"
cp -r "$WORK/dav1d/src" "$DEST/dav1d/"
# RISC-V and LoongArch/PowerPC are built without assembly; RISC-V still needs
# riscv/cpu.h.
find "$DEST/dav1d/src/riscv" -type f ! -name cpu.h -delete
find "$DEST/dav1d/src/riscv" -type d -empty -delete
rm -rf "$DEST/dav1d/src/loongarch" "$DEST/dav1d/src/ppc" \
  "$DEST/dav1d/src/meson.build" "$DEST/dav1d/src/dav1d.rc.in"

cp "$WORK/libyuv/LICENSE" "$WORK/libyuv/PATENTS" "$DEST/libyuv/"
cp -r "$WORK/libyuv/include" "$DEST/libyuv/"
for f in "${LIBYUV_SOURCES[@]}"; do
  cp "$WORK/libyuv/source/$f" "$DEST/libyuv/source/"
done

cat > "$DEST/VERSIONS" <<VERSIONS
libavif ${LIBAVIF_VERSION}
dav1d ${DAV1D_VERSION}
libyuv ${LIBYUV_REVISION}
VERSIONS

echo "Vendored libavif ${LIBAVIF_VERSION}, dav1d ${DAV1D_VERSION}, libyuv ${LIBYUV_REVISION}."
