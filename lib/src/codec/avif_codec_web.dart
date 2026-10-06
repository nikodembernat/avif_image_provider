// Copyright 2026 The avif_image_provider authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui_web' as ui_web;

import 'package:avif_image_provider/src/avif_exception.dart';
import 'package:avif_image_provider/src/codec/image_format.dart';
import 'package:flutter/painting.dart';

// On the web, AVIF images are decoded by the browser.
//
// Animated images go through Flutter's regular image decoding, which uses the
// browser's `ImageDecoder` API. Still images are decoded with
// `createImageBitmap` instead: Flutter always creates the `ImageDecoder` with
// `preferAnimation: true`, which makes Chromium fail to decode still (item
// based) AVIF images with "Failed to retrieve track metadata".

/// Decodes [bytes] as an AVIF image with the browser's decoder.
///
/// [getTargetSize] is called with the intrinsic size of the image to choose
/// the size of the decoded frames.
Future<ui.Codec> instantiateAvifCodec(
  Uint8List bytes, {
  ui.TargetImageSizeCallback? getTargetSize,
}) async {
  if (!_isStillAvif(bytes)) {
    return await ui.instantiateImageCodecWithSize(
      await ui.ImmutableBuffer.fromUint8List(bytes),
      getTargetSize: getTargetSize,
    );
  }
  return await _decodeStill(bytes, (width, height) async {
    final target = getTargetSize?.call(width, height);
    return resolveTargetSize(width, height, target?.width, target?.height);
  });
}

/// Decodes [bytes] for an [ImageProvider], using the browser's decoder.
Future<ui.Codec> decodeAvifForProvider(
  Uint8List bytes,
  ImageDecoderCallback decode,
) async {
  if (!_isStillAvif(bytes)) {
    return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }
  return await _decodeStill(
    bytes,
    (width, height) => probeTargetSize(decode, width, height),
  );
}

/// The versions of the bundled native libraries.
String get nativeLibraryVersions => 'browser';

bool _isStillAvif(Uint8List bytes) => isIsoBmff(bytes) && !hasMovieBox(bytes);

Future<ui.Codec> _decodeStill(
  Uint8List bytes,
  Future<(int, int)> Function(int width, int height) targetSize,
) async {
  final blob = _Blob([bytes.toJS].toJS, _BlobOptions(type: 'image/avif'));
  _ImageBitmap bitmap;
  try {
    bitmap = await _createImageBitmap(
      blob,
      _ImageBitmapOptions(
        imageOrientation: 'from-image',
        premultiplyAlpha: 'premultiply',
        colorSpaceConversion: 'default',
      ),
    ).toDart;
  } on Object catch (error) {
    throw AvifDecodeException('Failed to decode the AVIF image: $error');
  }

  final (width, height) = await targetSize(bitmap.width, bitmap.height);
  if (width != bitmap.width || height != bitmap.height) {
    final original = bitmap;
    try {
      bitmap = await _createImageBitmap(
        original,
        _ImageBitmapOptions.resized(
          resizeWidth: width,
          resizeHeight: height,
          resizeQuality: 'high',
          premultiplyAlpha: 'premultiply',
        ),
      ).toDart;
    } finally {
      original.close();
    }
  }
  return _StillCodec(await ui_web.createImageFromImageBitmap(bitmap));
}

/// A codec for a single, already decoded image.
final class _StillCodec(final ui.Image _image) implements ui.Codec {
  @override
  int get frameCount => 1;

  @override
  int get repetitionCount => 0;

  @override
  Future<ui.FrameInfo> getNextFrame() async =>
      _FrameInfo(Duration.zero, _image.clone());

  @override
  void dispose() => _image.dispose();
}

final class _FrameInfo(
  @override final Duration duration,
  @override final ui.Image image,
) implements ui.FrameInfo;

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory(JSArray<JSAny> parts, _BlobOptions options);
}

extension type _BlobOptions._(JSObject _) implements JSObject {
  external factory({String type});
}

extension type _ImageBitmapOptions._(JSObject _) implements JSObject {
  external factory({
    String imageOrientation,
    String premultiplyAlpha,
    String colorSpaceConversion,
  });

  external factory resized({
    int resizeWidth,
    int resizeHeight,
    String resizeQuality,
    String premultiplyAlpha,
  });
}

extension type _ImageBitmap._(JSObject _) implements JSObject {
  external int get width;
  external int get height;
  external void close();
}

@JS('createImageBitmap')
external JSPromise<_ImageBitmap> _createImageBitmap(
  JSObject source,
  _ImageBitmapOptions options,
);
