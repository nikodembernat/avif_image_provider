// Copyright 2026 The avif_image_provider authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:code_assets/code_assets.dart';

// Source lists of the vendored libraries, mirroring their upstream build files
// (dav1d: src/meson.build, libavif: CMakeLists.txt, libyuv: CMakeLists.txt).

List<Uri> _resolve(Uri root, String directory, List<String> files) => [
  for (final file in files) root.resolve('$directory$file'),
];

/// dav1d sources compiled once.
List<Uri> dav1dSources(Uri dav1d) => _resolve(dav1d, 'src/', const [
  'cdf.c',
  'cpu.c',
  'ctx.c',
  'data.c',
  'decode.c',
  'dequant_tables.c',
  'getbits.c',
  'intra_edge.c',
  'itx_1d.c',
  'lf_mask.c',
  'lib.c',
  'log.c',
  'mem.c',
  'msac.c',
  'obu.c',
  'pal.c',
  'picture.c',
  'qm.c',
  'ref.c',
  'refmvs.c',
  'scan.c',
  'tables.c',
  'thread_task.c',
  'warpmv.c',
  'wedge.c',
]);

/// dav1d sources compiled once per bit depth (8 and 16).
List<Uri> dav1dTemplateSources(Uri dav1d) => _resolve(dav1d, 'src/', const [
  'cdef_apply_tmpl.c',
  'cdef_tmpl.c',
  'fg_apply_tmpl.c',
  'filmgrain_tmpl.c',
  'ipred_prepare_tmpl.c',
  'ipred_tmpl.c',
  'itx_tmpl.c',
  'lf_apply_tmpl.c',
  'loopfilter_tmpl.c',
  'looprestoration_tmpl.c',
  'lr_apply_tmpl.c',
  'mc_tmpl.c',
  'recon_tmpl.c',
]);

/// dav1d Arm assembly in GNU assembler syntax.
List<Uri> dav1dGasSources(Uri dav1d, Architecture architecture) =>
    switch (architecture) {
      Architecture.arm64 => _resolve(dav1d, 'src/arm/64/', const [
        'itx.S',
        'looprestoration_common.S',
        'msac.S',
        'refmvs.S',
        // 8 bpc.
        'cdef.S',
        'filmgrain.S',
        'ipred.S',
        'loopfilter.S',
        'looprestoration.S',
        'mc.S',
        'mc_dotprod.S',
        // 16 bpc.
        'cdef16.S',
        'filmgrain16.S',
        'ipred16.S',
        'itx16.S',
        'loopfilter16.S',
        'looprestoration16.S',
        'mc16.S',
        'mc16_sve.S',
      ]),
      Architecture.arm => _resolve(dav1d, 'src/arm/32/', const [
        'itx.S',
        'looprestoration_common.S',
        'msac.S',
        'refmvs.S',
        // 8 bpc.
        'cdef.S',
        'filmgrain.S',
        'ipred.S',
        'loopfilter.S',
        'looprestoration.S',
        'mc.S',
        // 16 bpc.
        'cdef16.S',
        'filmgrain16.S',
        'ipred16.S',
        'itx16.S',
        'loopfilter16.S',
        'looprestoration16.S',
        'mc16.S',
      ]),
      _ => const [],
    };

/// dav1d x86 assembly in NASM syntax.
List<Uri> dav1dNasmSources(Uri dav1d) => _resolve(dav1d, 'src/x86/', const [
  'cpuid.asm',
  'msac.asm',
  'pal.asm',
  'refmvs.asm',
  'itx_avx512.asm',
  'cdef_avx2.asm',
  'itx_avx2.asm',
  'cdef_sse.asm',
  'itx_sse.asm',
  // 8 bpc.
  'cdef_avx512.asm',
  'filmgrain_avx512.asm',
  'ipred_avx512.asm',
  'loopfilter_avx512.asm',
  'looprestoration_avx512.asm',
  'mc_avx512.asm',
  'filmgrain_avx2.asm',
  'ipred_avx2.asm',
  'loopfilter_avx2.asm',
  'looprestoration_avx2.asm',
  'mc_avx2.asm',
  'filmgrain_sse.asm',
  'ipred_sse.asm',
  'loopfilter_sse.asm',
  'looprestoration_sse.asm',
  'mc_sse.asm',
  // 16 bpc.
  'cdef16_avx512.asm',
  'filmgrain16_avx512.asm',
  'ipred16_avx512.asm',
  'itx16_avx512.asm',
  'loopfilter16_avx512.asm',
  'looprestoration16_avx512.asm',
  'mc16_avx512.asm',
  'cdef16_avx2.asm',
  'filmgrain16_avx2.asm',
  'ipred16_avx2.asm',
  'itx16_avx2.asm',
  'loopfilter16_avx2.asm',
  'looprestoration16_avx2.asm',
  'mc16_avx2.asm',
  'cdef16_sse.asm',
  'filmgrain16_sse.asm',
  'ipred16_sse.asm',
  'itx16_sse.asm',
  'loopfilter16_sse.asm',
  'looprestoration16_sse.asm',
  'mc16_sse.asm',
]);

/// libavif sources (decoder with dav1d and libyuv).
List<Uri> libavifSources(Uri libavif) => _resolve(libavif, 'src/', const [
  'alpha.c',
  'avif.c',
  'codec_dav1d.c',
  'colr.c',
  'colrconvert.c',
  'diag.c',
  'exif.c',
  'gainmap.c',
  'io.c',
  'mem.c',
  'obu.c',
  'properties.c',
  'rawdata.c',
  'read.c',
  'reformat.c',
  'reformat_libsharpyuv.c',
  'reformat_libyuv.c',
  'sampletransform.c',
  'scale.c',
  'stream.c',
  'utils.c',
  'write.c',
]);

/// libyuv sources compiled for every architecture.
List<Uri> libyuvSources(Uri libyuv) => _resolve(libyuv, 'source/', const [
  'compare.cc',
  'compare_common.cc',
  'compare_gcc.cc',
  'compare_win.cc',
  'convert.cc',
  'convert_argb.cc',
  'convert_from.cc',
  'convert_from_argb.cc',
  'convert_to_argb.cc',
  'convert_to_i420.cc',
  'cpu_id.cc',
  'planar_functions.cc',
  'rotate.cc',
  'rotate_any.cc',
  'rotate_argb.cc',
  'rotate_common.cc',
  'rotate_gcc.cc',
  'rotate_win.cc',
  'row_any.cc',
  'row_common.cc',
  'row_gcc.cc',
  'row_win.cc',
  'scale.cc',
  'scale_any.cc',
  'scale_argb.cc',
  'scale_common.cc',
  'scale_gcc.cc',
  'scale_rgb.cc',
  'scale_uv.cc',
  'scale_win.cc',
  'video_common.cc',
]);

/// libyuv NEON sources for 32-bit Arm.
List<Uri> libyuvNeonSources(Uri libyuv) => _resolve(libyuv, 'source/', const [
  'compare_neon.cc',
  'rotate_neon.cc',
  'row_neon.cc',
  'scale_neon.cc',
]);

/// libyuv NEON sources for 64-bit Arm.
List<Uri> libyuvNeon64Sources(Uri libyuv) => _resolve(libyuv, 'source/', const [
  'compare_neon64.cc',
  'rotate_neon64.cc',
  'row_neon64.cc',
  'scale_neon64.cc',
]);

/// libyuv SVE2 sources for 64-bit Arm.
List<Uri> libyuvSveSources(Uri libyuv) =>
    _resolve(libyuv, 'source/', const ['row_sve.cc']);
