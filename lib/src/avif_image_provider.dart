// Copyright 2026 The avif_image_provider authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io' show File;
import 'dart:ui' as ui;

import 'package:avif_image_provider/src/codec/avif_codec.dart';
import 'package:avif_image_provider/src/network/network_loader_io.dart'
    if (dart.library.js_interop) 'package:avif_image_provider/src/network/network_loader_web.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

/// Base class for [ImageProvider]s of AVIF images.
///
/// Still and animated AVIF images are supported. On Android, iOS, macOS,
/// Linux and Windows the images are decoded with the bundled libavif and
/// dav1d libraries in a background isolate. On the web, the browser's
/// built-in AVIF decoder is used.
///
/// Other image formats supported by Flutter are decoded by Flutter itself, so
/// these providers can also be used when the format is not known in advance.
///
/// Decoding honors [ResizeImage] (and therefore `cacheWidth` and
/// `cacheHeight` of the `Image` widget): images are downscaled natively before
/// conversion to RGBA, which saves both time and memory.
///
/// Subclasses implement [loadBytes] to provide the encoded image.
abstract class const AvifImageProvider<T extends Object>({
  /// The scale to place in the [ImageInfo] object of the image.
  final double scale = 1.0,
}) extends ImageProvider<T> {
  /// Abstract const constructor.
  this;

  /// Loads the encoded image for [key].
  ///
  /// [chunkEvents] can be used to report loading progress.
  @protected
  Future<Uint8List> loadBytes(
    T key,
    StreamController<ImageChunkEvent> chunkEvents,
  );

  @override
  ImageStreamCompleter loadImage(T key, ImageDecoderCallback decode) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _loadCodec(key, decode, chunkEvents),
      chunkEvents: chunkEvents.stream,
      scale: scale,
      debugLabel: describeIdentity(key),
      informationCollector: () => [
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<T>('Image key', key),
      ],
    );
  }

  Future<ui.Codec> _loadCodec(
    T key,
    ImageDecoderCallback decode,
    StreamController<ImageChunkEvent> chunkEvents,
  ) async {
    try {
      final bytes = await loadBytes(key, chunkEvents);
      return await decodeAvifForProvider(bytes, decode);
    } catch (_) {
      // Do not keep failed images in the cache, so they can be retried.
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      rethrow;
    } finally {
      unawaited(chunkEvents.close());
    }
  }
}

/// Decodes the given [Uint8List] buffer as an AVIF image.
///
/// The provided [bytes] buffer should not be changed after it is provided to
/// a [MemoryAvifImage]. Like [MemoryImage], two [MemoryAvifImage]s are only
/// equal if they use the same buffer instance and scale.
///
/// See also:
///
///  * [AvifImageProvider], for details about decoding.
@immutable
class const MemoryAvifImage(
  /// The bytes to decode into an image.
  final Uint8List bytes, {
  super.scale,
}) extends AvifImageProvider<MemoryAvifImage> {
  /// Creates an object that decodes a [Uint8List] buffer as an AVIF image.
  this;

  @override
  Future<MemoryAvifImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<MemoryAvifImage>(this);

  @override
  Future<Uint8List> loadBytes(
    MemoryAvifImage key,
    StreamController<ImageChunkEvent> chunkEvents,
  ) => SynchronousFuture<Uint8List>(key.bytes);

  @override
  bool operator ==(Object other) =>
      other is MemoryAvifImage &&
      identical(other.bytes, bytes) &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(identityHashCode(bytes), scale);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'MemoryAvifImage')}'
      '(${describeIdentity(bytes)}, scale: ${scale.toStringAsFixed(1)})';
}

/// Decodes the given [File] as an AVIF image.
///
/// Not supported on the web.
///
/// See also:
///
///  * [AvifImageProvider], for details about decoding.
@immutable
class const FileAvifImage(
  /// The file to decode into an image.
  final File file, {
  super.scale,
}) extends AvifImageProvider<FileAvifImage> {
  /// Creates an object that decodes a [File] as an AVIF image.
  this;

  @override
  Future<FileAvifImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<FileAvifImage>(this);

  @override
  Future<Uint8List> loadBytes(
    FileAvifImage key,
    StreamController<ImageChunkEvent> chunkEvents,
  ) async {
    final bytes = await key.file.readAsBytes();
    if (bytes.isEmpty) {
      throw StateError(
        '${key.file} is empty and cannot be loaded as an image.',
      );
    }
    return bytes;
  }

  @override
  bool operator ==(Object other) =>
      other is FileAvifImage &&
      other.file.path == file.path &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(file.path, scale);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'FileAvifImage')}'
      '("${file.path}", scale: ${scale.toStringAsFixed(1)})';
}

/// The key used by [AssetAvifImage] for the image cache.
@immutable
class const AvifAssetBundleKey({
  /// The bundle from which the image will be obtained.
  required final AssetBundle bundle,

  /// The key to use to obtain the resource from the [bundle].
  required final String name,

  /// The scale to place in the [ImageInfo] object of the image.
  required final double scale,
}) {
  /// Creates the key for an AVIF asset.
  this;

  @override
  bool operator ==(Object other) =>
      other is AvifAssetBundleKey &&
      other.bundle == bundle &&
      other.name == name &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(bundle, name, scale);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'AvifAssetBundleKey')}'
      '(bundle: $bundle, name: "$name", scale: ${scale.toStringAsFixed(1)})';
}

/// Decodes an asset as an AVIF image.
///
/// Like [ExactAssetImage], the asset is used as-is: no resolution-aware asset
/// variant is chosen, and the [scale] is given explicitly.
///
/// See also:
///
///  * [AvifImageProvider], for details about decoding.
@immutable
class const AssetAvifImage(
  /// The name of the asset.
  final String assetName, {

  /// The bundle from which the image will be obtained.
  final AssetBundle? bundle,

  /// The name of the package from which the image is included.
  final String? package,
  super.scale,
}) extends AvifImageProvider<AvifAssetBundleKey> {
  /// Creates an object that decodes an asset as an AVIF image.
  ///
  /// If [bundle] is null, the bundle of the [ImageConfiguration] (usually the
  /// `DefaultAssetBundle` of the widget tree) or [rootBundle] is used.
  ///
  /// The [package] argument must be non-null when fetching an asset that is
  /// included in a package.
  this;

  /// The key to use to obtain the resource from the [bundle]. This is the
  /// argument passed to [AssetBundle.load].
  String get keyName =>
      package == null ? assetName : 'packages/$package/$assetName';

  @override
  Future<AvifAssetBundleKey> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<AvifAssetBundleKey>(
        AvifAssetBundleKey(
          bundle: bundle ?? configuration.bundle ?? rootBundle,
          name: keyName,
          scale: scale,
        ),
      );

  @override
  Future<Uint8List> loadBytes(
    AvifAssetBundleKey key,
    StreamController<ImageChunkEvent> chunkEvents,
  ) async {
    final data = await key.bundle.load(key.name);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  @override
  bool operator ==(Object other) =>
      other is AssetAvifImage &&
      other.keyName == keyName &&
      other.bundle == bundle &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(keyName, bundle, scale);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'AssetAvifImage')}'
      '(bundle: $bundle, name: "$keyName", scale: ${scale.toStringAsFixed(1)})';
}

/// Fetches the given URL from the network and decodes it as an AVIF image.
///
/// On the web, the image is downloaded with the browser's `fetch`, which
/// (like for [NetworkImage]) requires the server to allow cross-origin
/// requests (CORS) when the image is hosted on a different origin.
///
/// See also:
///
///  * [AvifImageProvider], for details about decoding.
@immutable
class const NetworkAvifImage(
  /// The URL from which the image will be fetched.
  final String url, {
  super.scale,

  /// The HTTP headers that will be used to fetch the image from the network.
  final Map<String, String>? headers,
}) extends AvifImageProvider<NetworkAvifImage> {
  /// Creates an object that fetches the image at the given URL.
  this;

  @override
  Future<NetworkAvifImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<NetworkAvifImage>(this);

  @override
  Future<Uint8List> loadBytes(
    NetworkAvifImage key,
    StreamController<ImageChunkEvent> chunkEvents,
  ) => loadNetworkBytes(key.url, key.headers, chunkEvents);

  @override
  bool operator ==(Object other) =>
      other is NetworkAvifImage && other.url == url && other.scale == scale;

  @override
  int get hashCode => Object.hash(url, scale);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'NetworkAvifImage')}'
      '("$url", scale: ${scale.toStringAsFixed(1)})';
}
