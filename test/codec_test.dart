// Copyright 2026 The avif_image_provider authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:ui' as ui;

import 'package:avif_image_provider/avif_image_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';
import 'test_utils.dart';

// These tests run both with the native decoder (`flutter test`) and with the
// browser's decoder (`flutter test --platform chrome`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ui.Codec> codecFor(
    String name, {
    ui.TargetImageSizeCallback? getTargetSize,
  }) => instantiateAvifCodec(fixtures[name]!, getTargetSize: getTargetSize);

  group('still images', () {
    test('decodes 4:4:4 images', () async {
      final codec = await codecFor('quadrants_444.avif');
      addTearDown(codec.dispose);
      expect(codec.frameCount, 1);
      expect(codec.repetitionCount, 0);

      final frame = await codec.getNextFrame();
      addTearDown(frame.image.dispose);
      expect(frame.image.width, 64);
      expect(frame.image.height, 48);
      expectQuadrants(
        await Pixels.of(frame.image),
        topLeft: red,
        topRight: green,
        bottomLeft: blue,
        bottomRight: white,
      );
    });

    test('decodes 4:2:0 images', () async {
      final codec = await codecFor('quadrants_420.avif');
      addTearDown(codec.dispose);
      final frame = await codec.getNextFrame();
      addTearDown(frame.image.dispose);
      expect((frame.image.width, frame.image.height), (64, 48));
      expectQuadrants(
        await Pixels.of(frame.image),
        topLeft: red,
        topRight: green,
        bottomLeft: blue,
        bottomRight: white,
        tolerance: 12,
      );
    });

    test('decodes the same frame again', () async {
      final codec = await codecFor('quadrants_444.avif');
      addTearDown(codec.dispose);
      final first = await codec.getNextFrame();
      first.image.dispose();
      final second = await codec.getNextFrame();
      addTearDown(second.image.dispose);
      expect(second.image.width, 64);
      expect((await Pixels.of(second.image)).at(0, 0), isColor(red));
    });

    test('decodes alpha', () async {
      final codec = await codecFor('alpha.avif');
      addTearDown(codec.dispose);
      final frame = await codec.getNextFrame();
      addTearDown(frame.image.dispose);
      final pixels = await Pixels.of(frame.image);
      expect(pixels.at(4, 16), isColor(red));
      expect(pixels.at(28, 16), isColor((0, 0, 255, 128), tolerance: 6));
    });

    test('applies the rotation of the image', () async {
      final codec = await codecFor('rotated.avif');
      addTearDown(codec.dispose);
      final frame = await codec.getNextFrame();
      addTearDown(frame.image.dispose);
      expect((frame.image.width, frame.image.height), (48, 64));
      expectQuadrants(
        await Pixels.of(frame.image),
        topLeft: blue,
        topRight: red,
        bottomLeft: white,
        bottomRight: green,
      );
    });

    test('decodes at the requested size', () async {
      final requested = <(int, int)>[];
      final codec = await codecFor(
        'quadrants_200x100.avif',
        getTargetSize: (width, height) {
          requested.add((width, height));
          return const ui.TargetImageSize(width: 50);
        },
      );
      addTearDown(codec.dispose);
      expect(requested, [(200, 100)]);
      final frame = await codec.getNextFrame();
      addTearDown(frame.image.dispose);
      expect((frame.image.width, frame.image.height), (50, 25));
      expectQuadrants(
        await Pixels.of(frame.image),
        topLeft: red,
        topRight: green,
        bottomLeft: blue,
        bottomRight: white,
      );
    });
  });

  group('animated images', () {
    test('decodes all frames and loops', () async {
      final codec = await codecFor('animated.avif');
      addTearDown(codec.dispose);
      expect(codec.frameCount, 3);
      expect(codec.repetitionCount, -1);

      final expected = [
        (red, const Duration(milliseconds: 100)),
        (green, const Duration(milliseconds: 200)),
        (blue, const Duration(milliseconds: 300)),
        // Wraps around to the first frame.
        (red, const Duration(milliseconds: 100)),
      ];
      for (final (color, duration) in expected) {
        final frame = await codec.getNextFrame();
        expect(frame.duration, duration);
        expect((frame.image.width, frame.image.height), (16, 16));
        expect((await Pixels.of(frame.image)).at(8, 8), isColor(color));
        frame.image.dispose();
      }
    });

    test('decodes transparent animations with a repetition count', () async {
      final codec = await codecFor('animated_alpha_loop1.avif');
      addTearDown(codec.dispose);
      expect(codec.frameCount, 2);
      // Browsers report the repetition count differently, see
      // https://github.com/w3c/webcodecs/issues/447.
      if (!kIsWeb) {
        expect(codec.repetitionCount, 1);
      }
      for (final color in [(255, 0, 0, 128), (0, 255, 0, 128)]) {
        final frame = await codec.getNextFrame();
        expect(frame.duration, const Duration(milliseconds: 50));
        expect(
          (await Pixels.of(frame.image)).at(8, 8),
          isColor(color, tolerance: 6),
        );
        frame.image.dispose();
      }
    });
  });

  test('decodes 12-bit animations', () async {
    final codec = await codecFor('colors-animated-12bpc-keyframes-0-2-3.avif');
    addTearDown(codec.dispose);
    expect(codec.frameCount, 5);
    for (final color in [
      (255, 120, 255, 255),
      (75, 255, 30, 255),
      (0, 136, 0, 125),
    ]) {
      final frame = await codec.getNextFrame();
      expect(frame.duration, const Duration(seconds: 1));
      expect((frame.image.width, frame.image.height), (64, 64));
      expect(
        (await Pixels.of(frame.image)).at(32, 32),
        isColor(color, tolerance: 8),
      );
      frame.image.dispose();
    }
  });

  test('throws for invalid images', () async {
    await expectLater(codecFor('not_avif.avif'), throwsA(isA<Exception>()));
  });
}
