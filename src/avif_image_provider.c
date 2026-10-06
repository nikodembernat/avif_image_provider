// Copyright 2026 The avif_image_provider authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "avif_image_provider.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "avif/avif.h"
#include "libyuv/planar_functions.h"
#include "libyuv/rotate_argb.h"
#include "libyuv/scale.h"
#include "libyuv/scale_argb.h"
#include "libyuv/version.h"

// Maximum number of decoding threads for animated images.
#define AVIFIP_MAX_ANIMATION_THREADS 4
// Number of pixels per decoding thread.
#define AVIFIP_PIXELS_PER_THREAD (128 * 1024)

struct AvifipDecoder {
  avifDecoder* decoder;
  // Copy of the encoded bytes; libavif does not copy them.
  uint8_t* data;
  size_t size;
  // Requested output size before rotation (0 = intrinsic).
  uint32_t target_width;
  uint32_t target_height;
  // Region of the decoded image that is displayed (from `clap`).
  avifCropRect crop;
  // Whether `crop` can be applied to the YUV planes directly (without first
  // upsampling the chroma planes).
  avifBool crop_in_yuv;
  // Rotation in libyuv terms (clockwise degrees).
  int rotation;
  // -1: no mirroring, 0: top/bottom exchanged, 1: left/right exchanged.
  int mirror_axis;
  // Scratch image used to scale the YUV planes before conversion.
  avifImage* scaled;
  // Output of the YUV to RGBA conversion.
  avifRGBImage rgb;
  // Output of rotation/mirroring, if any.
  uint8_t* transformed;
  size_t transformed_size;
  int32_t parsed;
};

static uint32_t avifipMinU32(uint32_t a, uint32_t b) {
  return a < b ? a : b;
}

AvifipDecoder* avifip_decoder_create(void) {
  AvifipDecoder* d = (AvifipDecoder*)calloc(1, sizeof(AvifipDecoder));
  if (d == NULL) {
    return NULL;
  }
  d->decoder = avifDecoderCreate();
  if (d->decoder == NULL) {
    free(d);
    return NULL;
  }
  d->mirror_axis = -1;
  return d;
}

// Reads the transform properties of the parsed image.
static void avifipReadTransforms(AvifipDecoder* d) {
  const avifImage* image = d->decoder->image;
  d->crop.x = 0;
  d->crop.y = 0;
  d->crop.width = image->width;
  d->crop.height = image->height;
  d->crop_in_yuv = AVIF_TRUE;
  if (image->transformFlags & AVIF_TRANSFORM_CLAP) {
    avifCropRect rect;
    avifDiagnostics diag;
    avifDiagnosticsClearError(&diag);
    // An invalid clean aperture is ignored, like browsers do.
    if (avifCropRectFromCleanApertureBox(&rect, &image->clap, image->width,
                                         image->height, &diag) &&
        rect.width > 0 && rect.height > 0) {
      d->crop = rect;
      d->crop_in_yuv = !avifCropRectRequiresUpsampling(&rect, image->yuvFormat);
    }
  }

  d->rotation = 0;
  if (image->transformFlags & AVIF_TRANSFORM_IROT) {
    // `irot` is anti-clockwise, libyuv rotates clockwise.
    switch (image->irot.angle & 3) {
      case 1:
        d->rotation = 270;
        break;
      case 2:
        d->rotation = 180;
        break;
      case 3:
        d->rotation = 90;
        break;
      default:
        d->rotation = 0;
        break;
    }
  }
  d->mirror_axis = (image->transformFlags & AVIF_TRANSFORM_IMIR)
                       ? (int)(image->imir.axis & 1)
                       : -1;
}

static int avifipSwapsAxes(const AvifipDecoder* d) {
  return d->rotation == 90 || d->rotation == 270;
}

int32_t avifip_decoder_parse(AvifipDecoder* d,
                             const uint8_t* data,
                             size_t size,
                             int32_t max_threads,
                             AvifipImageInfo* out_info) {
  if (d == NULL || data == NULL || size == 0 || out_info == NULL) {
    return AVIFIP_RESULT_INVALID_ARGUMENT;
  }
  if (d->parsed) {
    return AVIFIP_RESULT_INVALID_STATE;
  }

  d->data = (uint8_t*)malloc(size);
  if (d->data == NULL) {
    return AVIFIP_RESULT_OUT_OF_MEMORY;
  }
  memcpy(d->data, data, size);
  d->size = size;

  avifDecoder* decoder = d->decoder;
  decoder->maxThreads = max_threads < 1 ? 1 : max_threads;
  decoder->codecChoice = AVIF_CODEC_CHOICE_AUTO;
  decoder->ignoreExif = AVIF_TRUE;
  decoder->ignoreXMP = AVIF_TRUE;
  // Real-world files are often slightly non-conforming; decode them anyway,
  // like web browsers do.
  decoder->strictFlags = AVIF_STRICT_DISABLED;

  avifResult result = avifDecoderSetIOMemory(decoder, d->data, d->size);
  if (result != AVIF_RESULT_OK) {
    return (int32_t)result;
  }
  result = avifDecoderParse(decoder);
  if (result != AVIF_RESULT_OK) {
    return (int32_t)result;
  }
  if (decoder->imageCount < 1) {
    return (int32_t)AVIF_RESULT_NO_CONTENT;
  }

  d->parsed = 1;
  avifipReadTransforms(d);
  // Threads only pay off for large images: for small frames the
  // synchronization overhead outweighs the gains (a 256x256 frame decodes
  // twice as fast with one thread as with four).
  const uint64_t pixels =
      (uint64_t)decoder->image->width * (uint64_t)decoder->image->height;
  uint64_t useful_threads = pixels / AVIFIP_PIXELS_PER_THREAD;
  if (decoder->imageCount > 1 &&
      useful_threads > AVIFIP_MAX_ANIMATION_THREADS) {
    // Every animated image keeps its own dav1d thread pool alive.
    useful_threads = AVIFIP_MAX_ANIMATION_THREADS;
  }
  if (useful_threads < 1) {
    useful_threads = 1;
  }
  if ((uint64_t)decoder->maxThreads > useful_threads) {
    decoder->maxThreads = (int)useful_threads;
  }

  const int swap = avifipSwapsAxes(d);
  out_info->width = swap ? d->crop.height : d->crop.width;
  out_info->height = swap ? d->crop.width : d->crop.height;
  out_info->frame_count = (uint32_t)decoder->imageCount;
  if (decoder->imageCount <= 1) {
    out_info->repetition_count = 0;
  } else if (decoder->repetitionCount < 0) {
    // Both AVIF_REPETITION_COUNT_INFINITE and AVIF_REPETITION_COUNT_UNKNOWN
    // (no edit list) loop forever, which matches browser behavior.
    out_info->repetition_count = -1;
  } else {
    out_info->repetition_count = decoder->repetitionCount;
  }
  out_info->bit_depth = decoder->image->depth;
  out_info->has_alpha = decoder->alphaPresent ? 1 : 0;
  return AVIFIP_RESULT_OK;
}

int32_t avifip_decoder_set_target_size(AvifipDecoder* d,
                                       uint32_t width,
                                       uint32_t height) {
  if (d == NULL) {
    return AVIFIP_RESULT_INVALID_ARGUMENT;
  }
  // The target size is given in display orientation; store it in the
  // orientation of the encoded image.
  if (avifipSwapsAxes(d)) {
    d->target_width = height;
    d->target_height = width;
  } else {
    d->target_width = width;
    d->target_height = height;
  }
  return AVIFIP_RESULT_OK;
}

// Returns the size (before rotation) the cropped image is converted at.
static void avifipOutputSize(const AvifipDecoder* d,
                             uint32_t* width,
                             uint32_t* height) {
  *width = d->crop.width;
  *height = d->crop.height;
  if (d->target_width > 0) {
    *width = avifipMinU32(*width, d->target_width);
  }
  if (d->target_height > 0) {
    *height = avifipMinU32(*height, d->target_height);
  }
}

static avifResult avifipEnsureRgb(AvifipDecoder* d,
                                  const avifImage* image,
                                  int max_threads) {
  avifRGBImage* rgb = &d->rgb;
  if (rgb->pixels != NULL && rgb->width == image->width &&
      rgb->height == image->height) {
    return AVIF_RESULT_OK;
  }
  avifRGBImageFreePixels(rgb);
  avifRGBImageSetDefaults(rgb, image);
  rgb->format = AVIF_RGB_FORMAT_RGBA;
  rgb->depth = 8;
  rgb->alphaPremultiplied = AVIF_TRUE;
  rgb->chromaUpsampling = AVIF_CHROMA_UPSAMPLING_AUTOMATIC;
  rgb->maxThreads = max_threads;
  // avifRGBImageAllocatePixels() always produces packed rows.
  return avifRGBImageAllocatePixels(rgb);
}

// Converts the current decoder image to RGBA, applying crop and scale.
// On success, `*pixels`/`*row_bytes`/`*width`/`*height` describe the result.
static avifResult avifipConvert(AvifipDecoder* d,
                                uint8_t** pixels,
                                uint32_t* row_bytes,
                                uint32_t* width,
                                uint32_t* height) {
  avifImage* image = d->decoder->image;
  avifImage view;
  memset(&view, 0, sizeof(view));
  const avifImage* source = image;

  const avifBool cropped = d->crop.x != 0 || d->crop.y != 0 ||
                           d->crop.width != image->width ||
                           d->crop.height != image->height;
  if (cropped && d->crop_in_yuv) {
    avifResult result = avifImageSetViewRect(&view, image, &d->crop);
    if (result != AVIF_RESULT_OK) {
      return result;
    }
    source = &view;
  }

  uint32_t out_width;
  uint32_t out_height;
  avifipOutputSize(d, &out_width, &out_height);

  const avifBool scale =
      out_width != d->crop.width || out_height != d->crop.height;
  if (scale && (!cropped || d->crop_in_yuv)) {
    // Scale the YUV planes; this is much cheaper than converting at full size.
    if (d->scaled == NULL) {
      d->scaled = avifImageCreateEmpty();
      if (d->scaled == NULL) {
        return AVIF_RESULT_OUT_OF_MEMORY;
      }
    }
    avifResult result = avifImageCopy(d->scaled, source, AVIF_PLANES_ALL);
    if (result != AVIF_RESULT_OK) {
      return result;
    }
    result =
        avifImageScale(d->scaled, out_width, out_height, &d->decoder->diag);
    if (result != AVIF_RESULT_OK) {
      return result;
    }
    source = d->scaled;
  }

  avifResult result = avifipEnsureRgb(d, source, d->decoder->maxThreads);
  if (result != AVIF_RESULT_OK) {
    return result;
  }
  result = avifImageYUVToRGB(source, &d->rgb);
  if (result != AVIF_RESULT_OK) {
    return result;
  }

  *pixels = d->rgb.pixels;
  *width = d->rgb.width;
  *height = d->rgb.height;
  if (cropped && !d->crop_in_yuv) {
    // The crop rectangle is not aligned with the chroma planes, so crop the
    // RGBA output instead. Rows are moved in place to keep the frame packed.
    const size_t crop_row_bytes = (size_t)d->crop.width * 4;
    const uint8_t* src = d->rgb.pixels + (size_t)d->crop.y * d->rgb.rowBytes +
                         (size_t)d->crop.x * 4;
    for (uint32_t y = 0; y < d->crop.height; ++y) {
      memmove(d->rgb.pixels + y * crop_row_bytes,
              src + (size_t)y * d->rgb.rowBytes, crop_row_bytes);
    }
    *width = d->crop.width;
    *height = d->crop.height;
    if (scale) {
      // Rare: unaligned crop combined with downscaling. Scale the RGBA output.
      const size_t needed = (size_t)out_width * out_height * 4;
      uint8_t* scaled = (uint8_t*)malloc(needed);
      if (scaled == NULL) {
        return AVIF_RESULT_OUT_OF_MEMORY;
      }
      if (ARGBScale(d->rgb.pixels, (int)crop_row_bytes, (int)*width,
                    (int)*height, scaled, (int)out_width * 4, (int)out_width,
                    (int)out_height, kFilterBox) != 0) {
        free(scaled);
        return AVIF_RESULT_UNKNOWN_ERROR;
      }
      memcpy(d->rgb.pixels, scaled, needed);
      free(scaled);
      *width = out_width;
      *height = out_height;
    }
  }
  *row_bytes = *width * 4;
  return AVIF_RESULT_OK;
}

// Applies rotation and mirroring to the converted frame.
static avifResult avifipTransform(AvifipDecoder* d,
                                  uint8_t** pixels,
                                  uint32_t* row_bytes,
                                  uint32_t* width,
                                  uint32_t* height) {
  if (d->rotation == 0 && d->mirror_axis < 0) {
    return AVIF_RESULT_OK;
  }
  const size_t needed = (size_t)(*width) * (*height) * 4;
  if (d->transformed_size < needed) {
    free(d->transformed);
    d->transformed = (uint8_t*)malloc(needed);
    if (d->transformed == NULL) {
      d->transformed_size = 0;
      return AVIF_RESULT_OUT_OF_MEMORY;
    }
    d->transformed_size = needed;
  }

  uint32_t w = *width;
  uint32_t h = *height;
  uint8_t* src = *pixels;
  int src_stride = (int)*row_bytes;
  uint8_t* dst = d->transformed;

  if (d->rotation != 0) {
    const uint32_t dst_w = avifipSwapsAxes(d) ? h : w;
    const uint32_t dst_h = avifipSwapsAxes(d) ? w : h;
    if (ARGBRotate(src, src_stride, dst, (int)dst_w * 4, (int)w, (int)h,
                   (enum RotationMode)d->rotation) != 0) {
      return AVIF_RESULT_UNKNOWN_ERROR;
    }
    w = dst_w;
    h = dst_h;
    if (d->mirror_axis >= 0) {
      // Mirror in place into the RGB buffer, which is large enough.
      src = dst;
      src_stride = (int)w * 4;
      dst = d->rgb.pixels;
    }
  }

  if (d->mirror_axis == 1) {
    if (ARGBMirror(src, src_stride, dst, (int)w * 4, (int)w, (int)h) != 0) {
      return AVIF_RESULT_UNKNOWN_ERROR;
    }
  } else if (d->mirror_axis == 0) {
    // A negative height flips the image vertically.
    if (ARGBCopy(src, src_stride, dst, (int)w * 4, (int)w, -(int)h) != 0) {
      return AVIF_RESULT_UNKNOWN_ERROR;
    }
  }

  *pixels = dst;
  *row_bytes = w * 4;
  *width = w;
  *height = h;
  return AVIF_RESULT_OK;
}

int32_t avifip_decoder_decode_frame(AvifipDecoder* d, AvifipFrame* out_frame) {
  if (d == NULL || out_frame == NULL) {
    return AVIFIP_RESULT_INVALID_ARGUMENT;
  }
  if (!d->parsed) {
    return AVIFIP_RESULT_INVALID_STATE;
  }
  avifDecoder* decoder = d->decoder;
  avifResult result;
  if (decoder->imageIndex + 1 >= decoder->imageCount) {
    // Wrap around to the first frame (also used for still images).
    result = avifDecoderNthImage(decoder, 0);
  } else {
    result = avifDecoderNextImage(decoder);
  }
  if (result != AVIF_RESULT_OK) {
    return (int32_t)result;
  }

  uint8_t* pixels = NULL;
  uint32_t row_bytes = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  result = avifipConvert(d, &pixels, &row_bytes, &width, &height);
  if (result != AVIF_RESULT_OK) {
    return (int32_t)result;
  }
  result = avifipTransform(d, &pixels, &row_bytes, &width, &height);
  if (result != AVIF_RESULT_OK) {
    return (int32_t)result;
  }

  out_frame->pixels = pixels;
  out_frame->width = width;
  out_frame->height = height;
  out_frame->row_bytes = row_bytes;
  out_frame->index = (uint32_t)decoder->imageIndex;
  out_frame->duration_us =
      decoder->imageCount > 1
          ? (int64_t)(decoder->imageTiming.duration * 1e6 + 0.5)
          : 0;
  return AVIFIP_RESULT_OK;
}

const char* avifip_decoder_error_message(const AvifipDecoder* d,
                                         int32_t result) {
  if (d != NULL && d->decoder != NULL && d->decoder->diag.error[0] != '\0') {
    return d->decoder->diag.error;
  }
  switch (result) {
    case AVIFIP_RESULT_OK:
      return "OK";
    case AVIFIP_RESULT_INVALID_ARGUMENT:
      return "Invalid argument";
    case AVIFIP_RESULT_OUT_OF_MEMORY:
      return "Out of memory";
    case AVIFIP_RESULT_INVALID_STATE:
      return "Invalid decoder state";
    default:
      return avifResultToString((avifResult)result);
  }
}

void avifip_decoder_destroy(AvifipDecoder* d) {
  if (d == NULL) {
    return;
  }
  avifRGBImageFreePixels(&d->rgb);
  if (d->scaled != NULL) {
    avifImageDestroy(d->scaled);
  }
  if (d->decoder != NULL) {
    avifDecoderDestroy(d->decoder);
  }
  free(d->transformed);
  free(d->data);
  free(d);
}

const char* avifip_version(void) {
  static char version[256];
  if (version[0] == '\0') {
    char codecs[256];
    avifCodecVersions(codecs);
    snprintf(version, sizeof(version), "libavif %s (%s), libyuv %d",
             avifVersion(), codecs, LIBYUV_VERSION);
  }
  return version;
}
