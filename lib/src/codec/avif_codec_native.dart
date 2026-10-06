// Copyright 2026 The avif_image_provider authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:avif_image_provider/src/avif_exception.dart';
import 'package:avif_image_provider/src/codec/image_format.dart';
import 'package:avif_image_provider/src/ffi/avif_bindings.g.dart' as native;
import 'package:ffi/ffi.dart';
import 'package:flutter/painting.dart';

/// Maximum number of threads used to decode a single image.
final int _maxThreads = math.min(Platform.numberOfProcessors, 8);

/// Decodes [bytes] as an AVIF image with the bundled native decoder.
///
/// [getTargetSize] is called with the intrinsic size of the image (after
/// rotation and cropping) to choose the size of the decoded frames.
Future<ui.Codec> instantiateAvifCodec(
  Uint8List bytes, {
  ui.TargetImageSizeCallback? getTargetSize,
}) async {
  final decoder = await _ParsedDecoder.parse(bytes);
  try {
    final target = getTargetSize?.call(decoder.width, decoder.height);
    return decoder.toCodec(
      targetWidth: target?.width,
      targetHeight: target?.height,
    );
  } catch (_) {
    decoder.destroy();
    rethrow;
  }
}

/// Decodes [bytes] for an [ImageProvider].
///
/// AVIF images are decoded natively; anything else is handed to [decode]. The
/// target size requested by [decode] (e.g. by [ResizeImage]) is honored.
Future<ui.Codec> decodeAvifForProvider(
  Uint8List bytes,
  ImageDecoderCallback decode,
) async {
  if (!isIsoBmff(bytes)) {
    return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }
  final decoder = await _ParsedDecoder.parse(bytes);
  try {
    final (width, height) = await probeTargetSize(
      decode,
      decoder.width,
      decoder.height,
    );
    return decoder.toCodec(targetWidth: width, targetHeight: height);
  } catch (_) {
    decoder.destroy();
    rethrow;
  }
}

typedef _ParseResult = ({
  int code,
  String error,
  int width,
  int height,
  int frameCount,
  int repetitionCount,
});

typedef _FrameResult = ({
  int code,
  String error,
  int pixels,
  int width,
  int height,
  int rowBytes,
  int durationUs,
});

String _errorMessage(Pointer<native.AvifipDecoder> decoder, int code) => native
    .avifip_decoder_error_message(decoder, code)
    .cast<Utf8>()
    .toDartString();

/// Parses the container. Runs in a background isolate.
_ParseResult _parse(int decoderAddress, int data, int length, int threads) {
  final decoder = Pointer<native.AvifipDecoder>.fromAddress(decoderAddress);
  final info = calloc<native.AvifipImageInfo>();
  try {
    final code = native.avifip_decoder_parse(
      decoder,
      Pointer.fromAddress(data),
      length,
      threads,
      info,
    );
    return (
      code: code,
      error: code == native.AVIFIP_RESULT_OK
          ? ''
          : _errorMessage(decoder, code),
      width: info.ref.width,
      height: info.ref.height,
      frameCount: info.ref.frame_count,
      repetitionCount: info.ref.repetition_count,
    );
  } finally {
    calloc.free(info);
  }
}

/// Decodes the next frame. Runs in a background isolate.
_FrameResult _decodeFrame(int decoderAddress) {
  final decoder = Pointer<native.AvifipDecoder>.fromAddress(decoderAddress);
  final frame = calloc<native.AvifipFrame>();
  try {
    final code = native.avifip_decoder_decode_frame(decoder, frame);
    return (
      code: code,
      error: code == native.AVIFIP_RESULT_OK
          ? ''
          : _errorMessage(decoder, code),
      pixels: frame.ref.pixels.address,
      width: frame.ref.width,
      height: frame.ref.height,
      rowBytes: frame.ref.row_bytes,
      durationUs: frame.ref.duration_us,
    );
  } finally {
    calloc.free(frame);
  }
}

// The closures passed to Isolate.run are created in these functions so that
// they only capture integers.
Future<_ParseResult> _parseInBackground(
  int decoder,
  int data,
  int length,
  int threads,
) => Isolate.run(() => _parse(decoder, data, length, threads));

Future<_FrameResult> _decodeFrameInBackground(int decoder) =>
    Isolate.run(() => _decodeFrame(decoder));

/// A native decoder whose container has been parsed.
final class _ParsedDecoder._(
  final Pointer<native.AvifipDecoder> _decoder, {
  required final int width,
  required final int height,
  required final int frameCount,
  required final int repetitionCount,
}) {
  static Future<_ParsedDecoder> parse(Uint8List bytes) async {
    if (bytes.isEmpty) {
      throw const AvifDecodeException('The image data is empty.');
    }
    final decoder = native.avifip_decoder_create();
    if (decoder == nullptr) {
      throw const AvifDecodeException(
        'Failed to create the decoder.',
        code: native.AVIFIP_RESULT_OUT_OF_MEMORY,
      );
    }
    final data = malloc<Uint8>(bytes.length);
    final _ParseResult result;
    try {
      data.asTypedList(bytes.length).setAll(0, bytes);
      result = await _parseInBackground(
        decoder.address,
        data.address,
        bytes.length,
        _maxThreads,
      );
    } catch (_) {
      native.avifip_decoder_destroy(decoder);
      rethrow;
    } finally {
      // The decoder keeps its own copy of the data.
      malloc.free(data);
    }
    if (result.code != native.AVIFIP_RESULT_OK) {
      native.avifip_decoder_destroy(decoder);
      throw AvifDecodeException(
        'Failed to parse the AVIF image: ${result.error}',
        code: result.code,
      );
    }
    return _ParsedDecoder._(
      decoder,
      width: result.width,
      height: result.height,
      frameCount: result.frameCount,
      repetitionCount: result.repetitionCount,
    );
  }

  void destroy() => native.avifip_decoder_destroy(_decoder);

  /// Creates a codec that decodes frames at the given size (defaults to the
  /// intrinsic size).
  ui.Codec toCodec({int? targetWidth, int? targetHeight}) {
    final (outputWidth, outputHeight) = resolveTargetSize(
      width,
      height,
      targetWidth,
      targetHeight,
    );
    // Downscaling is done natively, on the YUV planes; upscaling (only
    // requested with ResizeImage.allowUpscaling) is left to the engine.
    native.avifip_decoder_set_target_size(
      _decoder,
      math.min(outputWidth, width),
      math.min(outputHeight, height),
    );
    return _AvifCodec(
      _decoder,
      frameCount: frameCount,
      repetitionCount: repetitionCount,
      outputWidth: outputWidth,
      outputHeight: outputHeight,
    );
  }
}

/// A [ui.Codec] backed by the native decoder.
///
/// Frames are decoded in a background isolate, so decoding never blocks the
/// UI thread.
final class _AvifCodec(
  Pointer<native.AvifipDecoder> decoder, {
  @override required final int frameCount,
  @override required final int repetitionCount,
  required final int outputWidth,
  required final int outputHeight,
}) implements ui.Codec, Finalizable {
  this {
    _finalizer.attach(this, decoder.cast(), detach: this);
  }

  /// Releases the native decoder if the codec is garbage collected without
  /// being disposed.
  static final _finalizer = NativeFinalizer(
    Native.addressOf<
          NativeFunction<Void Function(Pointer<native.AvifipDecoder>)>
        >(native.avifip_decoder_destroy)
        .cast(),
  );

  Pointer<native.AvifipDecoder>? _decoder = decoder;

  /// The decoded frame of a still image, which is decoded only once.
  ui.Image? _stillImage;
  bool _busy = false;
  bool _disposed = false;

  @override
  Future<ui.FrameInfo> getNextFrame() async {
    if (_disposed) {
      throw StateError('getNextFrame() called on a disposed codec.');
    }
    if (_stillImage case final image?) {
      return _FrameInfo(Duration.zero, image.clone());
    }
    if (_busy) {
      throw StateError(
        'getNextFrame() called before the previous call completed.',
      );
    }
    _busy = true;
    try {
      final frame = await _decodeFrameInBackground(_decoder!.address);
      if (frame.code != native.AVIFIP_RESULT_OK) {
        throw AvifDecodeException(
          'Failed to decode the AVIF image: ${frame.error}',
          code: frame.code,
        );
      }
      final image = await _createImage(frame);
      if (frameCount > 1) {
        return _FrameInfo(Duration(microseconds: frame.durationUs), image);
      }
      // A still image never changes, so the decoder is not needed anymore.
      _release();
      if (_disposed) {
        return _FrameInfo(Duration.zero, image);
      }
      _stillImage = image;
      return _FrameInfo(Duration.zero, image.clone());
    } finally {
      _busy = false;
      if (_disposed) {
        _release();
      }
    }
  }

  Future<ui.Image> _createImage(_FrameResult frame) async {
    // The pixels are owned by the native decoder; they are copied by
    // ImmutableBuffer.fromUint8List before the next frame is decoded.
    final pixels = Pointer<Uint8>.fromAddress(frame.pixels)
        .asTypedList(frame.rowBytes * frame.height);
    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: frame.width,
      height: frame.height,
      rowBytes: frame.rowBytes,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final resize = frame.width != outputWidth || frame.height != outputHeight;
    try {
      final codec = await descriptor.instantiateCodec(
        targetWidth: resize ? outputWidth : null,
        targetHeight: resize ? outputHeight : null,
      );
      try {
        return (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
      buffer.dispose();
    }
  }

  void _release() {
    final decoder = _decoder;
    if (decoder != null) {
      _decoder = null;
      _finalizer.detach(this);
      native.avifip_decoder_destroy(decoder);
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _stillImage?.dispose();
    _stillImage = null;
    if (!_busy) {
      _release();
    }
  }
}

final class _FrameInfo(
  @override final Duration duration,
  @override final ui.Image image,
) implements ui.FrameInfo;

/// The versions of the bundled native libraries.
String get nativeLibraryVersions =>
    native.avifip_version().cast<Utf8>().toDartString();
