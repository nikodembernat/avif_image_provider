// A C API on top of libavif + dav1d for Flutter.
//
// Frames are RGBA8888 with premultiplied alpha (what `ui.ImageDescriptor.raw`
// expects for `ui.PixelFormat.rgba8888`), with the `clap`, `irot` and `imir`
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

// Positive results are libavif `avifResult` codes.
enum {
  AVIFIP_RESULT_OK = 0,
  AVIFIP_RESULT_INVALID_ARGUMENT = -1,
  AVIFIP_RESULT_OUT_OF_MEMORY = -2,
  // E.g. decoding before parsing.
  AVIFIP_RESULT_INVALID_STATE = -3,
};

typedef struct AvifipDecoder AvifipDecoder;

typedef struct AvifipImageInfo {
  // Size of the displayed image, after all transforms.
  uint32_t width;
  uint32_t height;
  uint32_t frame_count;
  // Number of repetitions after the first playback; -1 repeats forever.
  int32_t repetition_count;
} AvifipImageInfo;

// The pixels are owned by the decoder and stay valid until the next
// `avifip_decoder_decode_frame` or `avifip_decoder_destroy` call.
typedef struct AvifipFrame {
  uint8_t* pixels;
  uint32_t width;
  uint32_t height;
  // Always `width * 4`: frames are packed.
  uint32_t row_bytes;
  int64_t duration_us;
} AvifipFrame;

// Returns NULL if out of memory.
AVIFIP_EXPORT AvifipDecoder* avifip_decoder_create(void);

// The encoded bytes are copied, so `data` may be released afterwards.
//
// At most `max_threads` threads are used; fewer for small images (where
// threading is slower) and at most 4 for animations.
AVIFIP_EXPORT int32_t avifip_decoder_parse(AvifipDecoder* decoder,
                                           const uint8_t* data,
                                           size_t size,
                                           int32_t max_threads,
                                           AvifipImageInfo* out_info);

// Decodes frames at a smaller size. Only downscaling is done; 0 (or a value
// not smaller than the intrinsic size) keeps the intrinsic size.
AVIFIP_EXPORT int32_t avifip_decoder_set_target_size(AvifipDecoder* decoder,
                                                     uint32_t width,
                                                     uint32_t height);

// After the last frame, decoding wraps around to the first one.
AVIFIP_EXPORT int32_t avifip_decoder_decode_frame(AvifipDecoder* decoder,
                                                  AvifipFrame* out_frame);

// Returns the last detailed error of `decoder`, or a description of `result`.
// Never returns NULL.
AVIFIP_EXPORT const char* avifip_decoder_error_message(
    const AvifipDecoder* decoder,
    int32_t result);

// Accepts NULL.
AVIFIP_EXPORT void avifip_decoder_destroy(AvifipDecoder* decoder);

// E.g. "libavif 1.4.2 (dav1d [dec]:1.5.4), libyuv 1924".
AVIFIP_EXPORT const char* avifip_version(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // AVIF_IMAGE_PROVIDER_H_
