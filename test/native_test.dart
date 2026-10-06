// Copyright 2026 The avif_image_provider authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

@TestOn('vm')
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:avif_image_provider/avif_image_provider.dart';
import 'package:avif_image_provider/src/codec/avif_codec.dart'
    show nativeLibraryVersions;
import 'package:avif_image_provider/src/codec/image_format.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundles libavif, dav1d and libyuv', () {
    expect(
      nativeLibraryVersions,
      allOf(contains('libavif 1.'), contains('dav1d'), contains('libyuv')),
    );
  });

  test('reports native errors', () async {
    await expectLater(
      instantiateAvifCodec(fixtures['not_avif.avif']!),
      throwsA(
        isA<AvifDecodeException>()
            .having((e) => e.code, 'code', isPositive)
            .having((e) => e.message, 'message', isNotEmpty),
      ),
    );
    await expectLater(
      instantiateAvifCodec(Uint8List(0)),
      throwsA(isA<AvifDecodeException>()),
    );
    // A truncated image fails to decode, not to parse.
    final truncated = fixtures['quadrants_444.avif']!;
    await expectLater(() async {
      final codec = await instantiateAvifCodec(
        Uint8List.sublistView(truncated, 0, truncated.length - 20),
      );
      try {
        await codec.getNextFrame();
      } finally {
        codec.dispose();
      }
    }(), throwsA(isA<AvifDecodeException>()));
  });

  test('disposing a codec while decoding is safe', () async {
    final codec = await instantiateAvifCodec(fixtures['animated.avif']!);
    final frame = codec.getNextFrame();
    codec.dispose();
    (await frame).image.dispose();
    expect(codec.getNextFrame, throwsStateError);
  });

  test('rejects concurrent getNextFrame calls', () async {
    final codec = await instantiateAvifCodec(fixtures['animated.avif']!);
    addTearDown(codec.dispose);
    final frame = codec.getNextFrame();
    expect(codec.getNextFrame, throwsStateError);
    (await frame).image.dispose();
  });

  test('decodes many images concurrently', () async {
    final codecs = await Future.wait([
      for (var i = 0; i < 32; i++)
        instantiateAvifCodec(
          fixtures[i.isEven ? 'animated.avif' : 'quadrants_420.avif']!,
        ),
    ]);
    final frames = await Future.wait([
      for (final codec in codecs) codec.getNextFrame(),
    ]);
    for (final frame in frames) {
      expect(frame.image.width, greaterThan(0));
      frame.image.dispose();
    }
    for (final codec in codecs) {
      codec.dispose();
    }
  });

  test('the size probe image decodes at any size', () async {
    for (final (width, height) in [(1, 1), (7, 3), (4000, 3000)]) {
      final codec = await ui.instantiateImageCodecWithSize(
        await ui.ImmutableBuffer.fromUint8List(emptyRleBmp(width, height)),
        getTargetSize: (w, h) => ui.TargetImageSize(width: w ~/ 2 + 1),
      );
      final frame = await codec.getNextFrame();
      expect(frame.image.width, width ~/ 2 + 1);
      frame.image.dispose();
      codec.dispose();
    }
  });

  test('detects ISO BMFF files', () {
    expect(isIsoBmff(fixtures['alpha.avif']!), isTrue);
    expect(isIsoBmff(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])), isFalse);
  });
}
