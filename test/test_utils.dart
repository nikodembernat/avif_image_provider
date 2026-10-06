import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

const red = (255, 0, 0, 255);
const green = (0, 255, 0, 255);
const blue = (0, 0, 255, 255);
const white = (255, 255, 255, 255);

typedef Rgba = (int, int, int, int);

/// The pixels of an image, without premultiplied alpha.
final class Pixels._(final int width, final int height, final ByteData _data) {
  static Future<Pixels> of(ui.Image image) async {
    final data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    return Pixels._(image.width, image.height, data!);
  }

  Rgba at(int x, int y) {
    final offset = (y * width + x) * 4;
    return (
      _data.getUint8(offset),
      _data.getUint8(offset + 1),
      _data.getUint8(offset + 2),
      _data.getUint8(offset + 3),
    );
  }
}

Matcher isColor(Rgba expected, {int tolerance = 4}) =>
    _ColorMatcher(expected, tolerance);

final class _ColorMatcher(final Rgba expected, final int tolerance)
    extends Matcher {
  @override
  bool matches(Object? item, Map<dynamic, dynamic> matchState) {
    if (item is! Rgba) {
      return false;
    }
    final (r, g, b, a) = item;
    final (er, eg, eb, ea) = expected;
    return (r - er).abs() <= tolerance &&
        (g - eg).abs() <= tolerance &&
        (b - eb).abs() <= tolerance &&
        (a - ea).abs() <= tolerance;
  }

  @override
  Description describe(Description description) =>
      description.add('color $expected (±$tolerance)');
}

void expectQuadrants(
  Pixels pixels, {
  required Rgba topLeft,
  required Rgba topRight,
  required Rgba bottomLeft,
  required Rgba bottomRight,
  int tolerance = 4,
}) {
  final left = pixels.width ~/ 4;
  final right = pixels.width * 3 ~/ 4;
  final top = pixels.height ~/ 4;
  final bottom = pixels.height * 3 ~/ 4;
  expect(pixels.at(left, top), isColor(topLeft, tolerance: tolerance));
  expect(pixels.at(right, top), isColor(topRight, tolerance: tolerance));
  expect(pixels.at(left, bottom), isColor(bottomLeft, tolerance: tolerance));
  expect(pixels.at(right, bottom), isColor(bottomRight, tolerance: tolerance));
}
