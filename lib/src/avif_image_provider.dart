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
/// Still and animated images are decoded with the bundled libavif and dav1d
/// in a background isolate, or by the browser on the web. Other formats are
/// decoded by Flutter. [ResizeImage] (`cacheWidth`/`cacheHeight`) is honored
/// by downscaling before the conversion to RGBA.
abstract class const AvifImageProvider<T extends Object>({
  /// The scale of the [ImageInfo].
  final double scale = 1.0,
}) extends ImageProvider<T> {
  /// Subclasses provide the encoded image through [loadBytes].
  this;

  /// Loads the encoded image; [chunkEvents] can report loading progress.
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

/// Decodes an AVIF image from memory.
///
/// Like [MemoryImage], two [MemoryAvifImage]s are only equal if they use the
/// same buffer instance and scale.
@immutable
class const MemoryAvifImage(final Uint8List bytes, {super.scale})
    extends AvifImageProvider<MemoryAvifImage> {
  /// [bytes] must not be modified afterwards.
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

/// Decodes an AVIF image from a file. Not supported on the web.
@immutable
class const FileAvifImage(final File file, {super.scale})
    extends AvifImageProvider<FileAvifImage> {
  /// [file] is read when the image is resolved.
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
  required final AssetBundle bundle,

  /// The key passed to [AssetBundle.load].
  required final String name,
  required final double scale,
}) {
  /// Usually created by [AssetAvifImage.obtainKey].
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

/// Decodes an AVIF image from an asset.
///
/// Like [ExactAssetImage], no resolution-aware asset variant is chosen.
@immutable
class const AssetAvifImage(
  final String assetName, {

  /// Defaults to the bundle of the [ImageConfiguration] (usually the
  /// `DefaultAssetBundle` of the widget tree), or [rootBundle].
  final AssetBundle? bundle,

  /// The package that contains the asset, if any.
  final String? package,
  super.scale,
}) extends AvifImageProvider<AvifAssetBundleKey> {
  /// [assetName] is relative to [package], if given.
  this;

  /// The key passed to [AssetBundle.load].
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

/// Downloads and decodes an AVIF image.
///
/// On the web, like [NetworkImage], images on other origins require CORS.
@immutable
class const NetworkAvifImage(
  final String url, {
  super.scale,
  final Map<String, String>? headers,
}) extends AvifImageProvider<NetworkAvifImage> {
  /// [headers] are sent with the request.
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
