// Copyright 2026 The avif_image_provider authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// A small C API on top of libavif + dav1d, tailored for Flutter.
//
// The decoder produces RGBA8888 frames with premultiplied alpha (the format
// expected by `ui.ImageDescriptor.raw` with `ui.PixelFormat.rgba8888`), with
// the clean aperture (`clap`), rotation (`irot`) and mirroring (`imir`)
// transforms already applied.

#ifndef AVIF_IMAGE_PROVIDER_H_
#define AVIF_IMAGE_PROVIDER_H_

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define AVIFIP_EXPORT __declspec(dllexport)
#else
#define AVIFIP_EXPORT \
  __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Result codes returned by the functions below.
//
// Positive values are libavif `avifResult` codes.
enum {
  AVIFIP_RESULT_OK = 0,
  // A required argument was NULL or otherwise invalid.
  AVIFIP_RESULT_INVALID_ARGUMENT = -1,
  // A memory allocation failed.
  AVIFIP_RESULT_OUT_OF_MEMORY = -2,
  // The function was called in the wrong order (e.g. decoding before parsing).
  AVIFIP_RESULT_INVALID_STATE = -3,
};

// Opaque decoder handle.
typedef struct AvifipDecoder AvifipDecoder;

// Information about a parsed image.
typedef struct AvifipImageInfo {
  // Width of the displayed image in pixels, after all transforms.
  uint32_t width;
  // Height of the displayed image in pixels, after all transforms.
  uint32_t height;
  // Number of frames. 1 for still images.
  uint32_t frame_count;
  // Number of times the animation should be repeated after the first
  // playback. -1 means that it repeats forever.
  int32_t repetition_count;
  // Bit depth of the encoded image (8, 10, 12 or 16).
  uint32_t bit_depth;
  // 1 if the image has an alpha channel, 0 otherwise.
  uint32_t has_alpha;
} AvifipImageInfo;

// A decoded frame. The pixel memory is owned by the decoder and stays valid
// until the next call to `avifip_decoder_decode_frame` or
// `avifip_decoder_destroy`.
typedef struct AvifipFrame {
  // RGBA8888 pixels with premultiplied alpha.
  uint8_t* pixels;
  // Width of the frame in pixels.
  uint32_t width;
  // Height of the frame in pixels.
  uint32_t height;
  // Number of bytes between the starts of two consecutive rows. Frames are
  // always packed, so this is `width * 4`.
  uint32_t row_bytes;
  // Zero-based index of the frame.
  uint32_t index;
  // How long the frame should be displayed, in microseconds.
  int64_t duration_us;
} AvifipFrame;

// Creates a new decoder. Returns NULL if out of memory.
AVIFIP_EXPORT AvifipDecoder* avifip_decoder_create(void);

// Parses the container of an encoded AVIF image.
//
// The encoded bytes are copied, so `data` may be released once this returns.
// `max_threads` limits the number of threads used for decoding; values below 1
// are treated as 1. Fewer threads are used for small images (where threading
// is slower) and animated images use at most 4 threads.
AVIFIP_EXPORT int32_t avifip_decoder_parse(AvifipDecoder* decoder,
                                           const uint8_t* data,
                                           size_t size,
                                           int32_t max_threads,
                                           AvifipImageInfo* out_info);

// Requests frames to be decoded at the given size instead of the intrinsic
// size. Only downscaling is performed natively; 0 (or a value not smaller than
// the intrinsic size) keeps the intrinsic size of that dimension.
AVIFIP_EXPORT int32_t avifip_decoder_set_target_size(AvifipDecoder* decoder,
                                                     uint32_t width,
                                                     uint32_t height);

// Decodes the next frame. After the last frame of an animation, decoding wraps
// around to the first frame.
AVIFIP_EXPORT int32_t avifip_decoder_decode_frame(AvifipDecoder* decoder,
                                                  AvifipFrame* out_frame);

// Returns a human-readable description of the last error of `decoder`, or of
// `result` if the decoder has no detailed error message. Never returns NULL.
AVIFIP_EXPORT const char* avifip_decoder_error_message(
    const AvifipDecoder* decoder,
    int32_t result);

// Destroys the decoder and releases all memory owned by it. Accepts NULL.
AVIFIP_EXPORT void avifip_decoder_destroy(AvifipDecoder* decoder);

// Returns the versions of the bundled libraries, e.g.
// "libavif 1.4.2 (dav1d [dec]:1.5.4), libyuv 1924".
AVIFIP_EXPORT const char* avifip_version(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // AVIF_IMAGE_PROVIDER_H_
