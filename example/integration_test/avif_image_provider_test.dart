import 'dart:ui' as ui;

import 'package:avif_image_provider/avif_image_provider.dart';
import 'package:avif_image_provider_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

typedef Rgba = (int, int, int, int);

Future<Uint8List> _asset(String name) async {
  final data = await rootBundle.load('assets/$name');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Future<Rgba> _pixel(ui.Image image, int x, int y) async {
  final data = (await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  ))!;
  final offset = (y * image.width + x) * 4;
  return (
    data.getUint8(offset),
    data.getUint8(offset + 1),
    data.getUint8(offset + 2),
    data.getUint8(offset + 3),
  );
}

Matcher _isColor(Rgba expected, {int tolerance = 6}) =>
    predicate<Rgba>((actual) {
      final (r, g, b, a) = actual;
      final (er, eg, eb, ea) = expected;
      return (r - er).abs() <= tolerance &&
          (g - eg).abs() <= tolerance &&
          (b - eb).abs() <= tolerance &&
          (a - ea).abs() <= tolerance;
    }, 'is color $expected (±$tolerance)');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('decoding', () {
    testWidgets('still image', (tester) async {
      final codec = await instantiateAvifCodec(
        await _asset('quadrants_444.avif'),
      );
      final frame = await codec.getNextFrame();
      expect((frame.image.width, frame.image.height), (64, 48));
      expect(await _pixel(frame.image, 16, 12), _isColor((255, 0, 0, 255)));
      expect(await _pixel(frame.image, 48, 12), _isColor((0, 255, 0, 255)));
      expect(await _pixel(frame.image, 16, 36), _isColor((0, 0, 255, 255)));
      expect(await _pixel(frame.image, 48, 36), _isColor((255, 255, 255, 255)));
      frame.image.dispose();
      codec.dispose();
    });

    testWidgets('transparency', (tester) async {
      final codec = await instantiateAvifCodec(await _asset('alpha.avif'));
      final frame = await codec.getNextFrame();
      expect(await _pixel(frame.image, 4, 16), _isColor((255, 0, 0, 255)));
      expect(await _pixel(frame.image, 28, 16), _isColor((0, 0, 255, 128)));
      frame.image.dispose();
      codec.dispose();
    });

    testWidgets('animation', (tester) async {
      final codec = await instantiateAvifCodec(await _asset('animated.avif'));
      expect(codec.frameCount, 3);
      expect(codec.repetitionCount, -1);
      for (final (color, milliseconds) in [
        ((255, 0, 0, 255), 100),
        ((0, 255, 0, 255), 200),
        ((0, 0, 255, 255), 300),
      ]) {
        final frame = await codec.getNextFrame();
        expect(frame.duration, Duration(milliseconds: milliseconds));
        expect(await _pixel(frame.image, 8, 8), _isColor(color));
        frame.image.dispose();
      }
      codec.dispose();
    });

    testWidgets('large animation', (tester) async {
      final codec = await instantiateAvifCodec(
        await _asset('plasma_animated.avif'),
      );
      expect(codec.frameCount, 48);
      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < codec.frameCount; i++) {
        final frame = await codec.getNextFrame();
        expect((frame.image.width, frame.image.height), (256, 256));
        frame.image.dispose();
      }
      // Printed so the decoding speed shows up in CI logs.
      // ignore: avoid_print
      print(
        'Decoded ${codec.frameCount} 256x256 frames in ${stopwatch.elapsed} '
        '(${stopwatch.elapsedMicroseconds ~/ codec.frameCount} µs/frame).',
      );
      codec.dispose();
    });

    testWidgets('downscaling', (tester) async {
      final codec = await instantiateAvifCodec(
        await _asset('plasma.avif'),
        getTargetSize: (width, height) {
          expect((width, height), (512, 512));
          return const ui.TargetImageSize(width: 128);
        },
      );
      final frame = await codec.getNextFrame();
      expect((frame.image.width, frame.image.height), (128, 128));
      frame.image.dispose();
      codec.dispose();
    });
  });

  testWidgets('example app shows all local images', (tester) async {
    await tester.pumpWidget(const AvifExampleApp());
    // The grid is lazy, so each example is scrolled into view before its
    // image is checked.
    const expectedSizes = {
      'Still image': (512, 512),
      'Animated image': (256, 256),
      'Transparency': (32, 32),
      'Decoded at 64 px (cacheWidth)': (64, 64),
    };
    for (final MapEntry(key: title, value: size) in expectedSizes.entries) {
      final label = find.text(title);
      await tester.scrollUntilVisible(label, 100);
      final image = find.descendant(
        of: find.ancestor(of: label, matching: find.byType(Card)),
        matching: find.byType(RawImage),
      );
      ui.Image? decoded;
      for (var i = 0; i < 100 && decoded == null; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        // Until the first frame is decoded, the example shows a progress
        // indicator instead of the image.
        decoded = tester.widgetList<RawImage>(image).firstOrNull?.image;
      }
      expect(decoded, isNotNull, reason: title);
      expect((decoded!.width, decoded.height), size, reason: title);
    }
    expect(find.byType(ErrorWidget), findsNothing);
  });
}
