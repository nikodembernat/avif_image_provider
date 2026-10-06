// Copyright 2026 The avif_image_provider authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io' show File;
import 'dart:ui' as ui;

import 'package:avif_image_provider/avif_image_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';
import 'test_utils.dart';

/// Encodes a 2x1 PNG image: a red and a green pixel.
Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder)
    ..drawRect(
      const ui.Rect.fromLTWH(0, 0, 1, 1),
      ui.Paint()..color = const ui.Color(0xFFFF0000),
    )
    ..drawRect(
      const ui.Rect.fromLTWH(1, 0, 1, 1),
      ui.Paint()..color = const ui.Color(0xFF00FF00),
    );
  final picture = recorder.endRecording();
  final image = await picture.toImage(2, 1);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

final class _FixtureBundle() extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final bytes = fixtures[key.split('/').last];
    if (bytes == null) {
      throw FlutterError('Asset not found: $key');
    }
    return ByteData.sublistView(bytes);
  }
}

/// Resolves [provider] and returns the first [ImageInfo], or throws the error
/// reported by the image stream.
Future<ImageInfo> _resolve(ImageProvider provider) {
  final completer = Completer<ImageInfo>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, synchronousCall) {
      stream.removeListener(listener);
      completer.complete(info);
    },
    onError: (error, stackTrace) {
      stream.removeListener(listener);
      completer.completeError(error, stackTrace);
    },
  );
  stream.addListener(listener);
  return completer.future;
}

/// Waits until the [RawImage] in the tree has an image and returns it.
Future<ui.Image> _waitForImage(WidgetTester tester) async {
  for (var i = 0; i < 500; i++) {
    final image = tester.widget<RawImage>(find.byType(RawImage)).image;
    if (image != null) {
      return image;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  throw StateError('The image was not decoded.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  test('MemoryAvifImage decodes an image', () async {
    final info = await _resolve(
      MemoryAvifImage(fixtures['quadrants_444.avif']!, scale: 2),
    );
    addTearDown(info.dispose);
    expect(info.scale, 2);
    expect((info.image.width, info.image.height), (64, 48));
    expectQuadrants(
      await Pixels.of(info.image),
      topLeft: red,
      topRight: green,
      bottomLeft: blue,
      bottomRight: white,
    );
  });

  test('ResizeImage decodes at the requested size', () async {
    final info = await _resolve(
      ResizeImage(
        MemoryAvifImage(fixtures['quadrants_200x100.avif']!),
        width: 40,
      ),
    );
    addTearDown(info.dispose);
    expect((info.image.width, info.image.height), (40, 20));
    expectQuadrants(
      await Pixels.of(info.image),
      topLeft: red,
      topRight: green,
      bottomLeft: blue,
      bottomRight: white,
      tolerance: 8,
    );
  });

  test('ResizeImage keeps small images by default', () async {
    final info = await _resolve(
      ResizeImage(MemoryAvifImage(fixtures['quadrants_444.avif']!), width: 640),
    );
    addTearDown(info.dispose);
    expect((info.image.width, info.image.height), (64, 48));
  });

  test(
    'ResizeImage upscales when allowed',
    () async {
      final info = await _resolve(
        ResizeImage(
          MemoryAvifImage(fixtures['quadrants_444.avif']!),
          width: 128,
          allowUpscaling: true,
        ),
      );
      addTearDown(info.dispose);
      expect((info.image.width, info.image.height), (128, 96));
    },
    // Like Flutter itself, the web never upscales decoded images.
    skip: kIsWeb ? 'Flutter web does not upscale images' : false,
  );

  test('other image formats are decoded by Flutter', () async {
    final info = await _resolve(MemoryAvifImage(await _png()));
    addTearDown(info.dispose);
    final pixels = await Pixels.of(info.image);
    expect((pixels.width, pixels.height), (2, 1));
    expect(pixels.at(0, 0), isColor(red));
    expect(pixels.at(1, 0), isColor(green));
  });

  test('reports errors for invalid images', () async {
    await expectLater(
      _resolve(MemoryAvifImage(fixtures['not_avif.avif']!)),
      throwsA(isA<Object>()),
    );
  });

  test('AssetAvifImage loads from the bundle', () async {
    final bundle = _FixtureBundle();
    const provider = AssetAvifImage('assets/alpha.avif', package: 'fixtures');
    final key = await provider.obtainKey(ImageConfiguration(bundle: bundle));
    expect(key.name, 'packages/fixtures/assets/alpha.avif');
    expect(key.bundle, bundle);

    final info = await _resolve(
      AssetAvifImage('alpha.avif', bundle: bundle, scale: 3),
    );
    addTearDown(info.dispose);
    expect(info.scale, 3);
    expect((info.image.width, info.image.height), (32, 32));
  });

  test('FileAvifImage loads from a file', () async {
    // Animated images only start once frames are pumped, so use a still one.
    final file = File('test/fixtures/alpha.avif');
    final info = await _resolve(FileAvifImage(file));
    addTearDown(info.dispose);
    expect((info.image.width, info.image.height), (32, 32));
  }, skip: kIsWeb ? 'Files are not supported on the web' : false);

  test('providers implement equality', () {
    final bytes = fixtures['alpha.avif']!;
    expect(MemoryAvifImage(bytes), MemoryAvifImage(bytes));
    expect(MemoryAvifImage(bytes).hashCode, MemoryAvifImage(bytes).hashCode);
    expect(
      MemoryAvifImage(bytes),
      isNot(MemoryAvifImage(Uint8List.fromList(bytes))),
    );
    expect(MemoryAvifImage(bytes), isNot(MemoryAvifImage(bytes, scale: 2)));

    expect(FileAvifImage(File('a.avif')), FileAvifImage(File('a.avif')));
    expect(FileAvifImage(File('a.avif')), isNot(FileAvifImage(File('b.avif'))));

    expect(
      const AssetAvifImage('a.avif', package: 'p'),
      const AssetAvifImage('packages/p/a.avif'),
    );
    expect(const AssetAvifImage('a.avif'), isNot(const AssetAvifImage('b')));

    expect(
      const NetworkAvifImage('https://example.com/a.avif'),
      const NetworkAvifImage('https://example.com/a.avif'),
    );
    expect(
      const NetworkAvifImage('https://example.com/a.avif'),
      isNot(const NetworkAvifImage('https://example.com/b.avif')),
    );
  });

  test('describes providers', () {
    expect(
      const NetworkAvifImage('https://example.com/a.avif').toString(),
      'NetworkAvifImage("https://example.com/a.avif", scale: 1.0)',
    );
    expect(
      FileAvifImage(File('a.avif'), scale: 2).toString(),
      'FileAvifImage("a.avif", scale: 2.0)',
    );
  });

  testWidgets('Image widget shows an AVIF image', (tester) async {
    final provider = MemoryAvifImage(fixtures['quadrants_444.avif']!);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: Image(image: provider)),
      ),
    );
    // Decoding happens outside of the fake async zone of widget tests.
    final image = await _waitForImage(tester);
    expect((image.width, image.height), (64, 48));
    expect(tester.getSize(find.byType(Image)), const Size(64, 48));
  });

  testWidgets('Image widget plays animations', (tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Image(image: MemoryAvifImage(fixtures['animated.avif']!)),
      ),
    );
    final colors = <Rgba>[];
    ui.Image? previous;
    for (var i = 0; i < 200 && colors.length < 4; i++) {
      final image = await _waitForImage(tester);
      // Every new frame is a new image object; the previous one may already
      // be disposed, so only compare identities.
      if (!identical(image, previous)) {
        previous = image;
        final pixels = await tester.runAsync(() => Pixels.of(image));
        colors.add(pixels!.at(8, 8));
      }
      // Let the next frame decode, then advance the animation clock.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(colors, [isColor(red), isColor(green), isColor(blue), isColor(red)]);
  });

  test('decoded images can be drawn', () async {
    final info = await _resolve(
      MemoryAvifImage(fixtures['quadrants_444.avif']!),
    );
    addTearDown(info.dispose);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImage(info.image, ui.Offset.zero, ui.Paint());
    final picture = recorder.endRecording();
    addTearDown(picture.dispose);
    final image = await picture.toImage(64, 48);
    addTearDown(image.dispose);
    expect((await Pixels.of(image)).at(60, 4), isColor(green));
  });
}
