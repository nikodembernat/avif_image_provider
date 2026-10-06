// Copyright 2026 The avif_image_provider authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Whether [bytes] start with an ISO base media file format `ftyp` box, which
/// AVIF (as well as HEIF and MP4) files do.
bool isIsoBmff(Uint8List bytes) =>
    bytes.length >= 12 &&
    bytes[4] == 0x66 && // f
    bytes[5] == 0x74 && // t
    bytes[6] == 0x79 && // y
    bytes[7] == 0x70; // p

/// Whether the ISO base media file [bytes] contain a top-level `moov` box,
/// i.e. an image sequence (animation).
bool hasMovieBox(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var offset = 0;
  while (offset + 8 <= data.lengthInBytes) {
    var size = data.getUint32(offset);
    final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
    if (type == 'moov') {
      return true;
    }
    if (size == 1) {
      if (offset + 16 > data.lengthInBytes) {
        return false;
      }
      final large =
          data.getUint32(offset + 8) * 0x100000000 +
          data.getUint32(offset + 12);
      size = large;
    } else if (size == 0) {
      // The box extends to the end of the file.
      return false;
    }
    if (size < 8) {
      return false;
    }
    offset += size;
  }
  return false;
}

/// Creates a [width] x [height] 8-bit run-length encoded BMP image whose pixel
/// data consists of a single "end of bitmap" marker, so it is fully
/// transparent and almost free to decode at any size.
Uint8List emptyRleBmp(int width, int height) {
  const fileHeaderSize = 14;
  const infoHeaderSize = 40;
  const paletteSize = 4;
  const dataOffset = fileHeaderSize + infoHeaderSize + paletteSize;
  const pixelData = [0x00, 0x01]; // End of bitmap.
  final bytes = ByteData(dataOffset + pixelData.length)
    // BITMAPFILEHEADER.
    ..setUint8(0, 0x42) // B
    ..setUint8(1, 0x4D) // M
    ..setUint32(2, dataOffset + pixelData.length, Endian.little)
    ..setUint32(10, dataOffset, Endian.little)
    // BITMAPINFOHEADER.
    ..setUint32(14, infoHeaderSize, Endian.little)
    ..setInt32(18, width, Endian.little)
    // Positive height: bottom-up rows, as required for RLE compression.
    ..setInt32(22, height, Endian.little)
    ..setUint16(26, 1, Endian.little) // Planes.
    ..setUint16(28, 8, Endian.little) // Bits per pixel.
    ..setUint32(30, 1, Endian.little) // BI_RLE8.
    ..setUint32(34, pixelData.length, Endian.little)
    ..setUint32(46, 1, Endian.little); // Colors used.
  // The single palette entry (black) is already zeroed.
  return bytes.buffer.asUint8List()..setAll(dataOffset, pixelData);
}

/// Finds out which size [decode] would decode an image of the given size at.
///
/// An [ImageProvider] only learns about [ResizeImage] through the decode
/// callback it receives, which only accepts encoded images. To honor it, a
/// tiny run-length encoded BMP of the same size (which decodes almost for
/// free) is decoded and the size of the result is used.
Future<(int, int)> probeTargetSize(
  ImageDecoderCallback decode,
  int width,
  int height,
) async {
  if (decode == PaintingBinding.instance.instantiateImageCodecWithSize) {
    return (width, height);
  }
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await decode(
      await ui.ImmutableBuffer.fromUint8List(emptyRleBmp(width, height)),
    );
    image = (await codec.getNextFrame()).image;
    return (image.width, image.height);
  } catch (_) {
    // The probe is best-effort: if it fails, the image is decoded at its
    // intrinsic size.
    return (width, height);
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

/// Computes the size of an image of [width] x [height] decoded with the
/// given target size, using the rules of `ui.instantiateImageCodec`: a
/// missing dimension keeps the aspect ratio.
(int, int) resolveTargetSize(
  int width,
  int height,
  int? targetWidth,
  int? targetHeight,
) {
  if (targetWidth == null && targetHeight == null) {
    return (width, height);
  }
  return (
    targetWidth ?? (width * targetHeight! / height).round().clamp(1, 1 << 30),
    targetHeight ?? (height * targetWidth! / width).round().clamp(1, 1 << 30),
  );
}
