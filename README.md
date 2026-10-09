# avif_image_provider

[![CI](https://github.com/nikodembernat/avif_image_provider/actions/workflows/ci.yml/badge.svg)](https://github.com/nikodembernat/avif_image_provider/actions/workflows/ci.yml)

Fast [AVIF](https://aomediacodec.github.io/av1-avif/) image providers for
Flutter, with support for **animated** AVIF images.

* **Native platforms** (Android, iOS, macOS, Linux, Windows): images are
  decoded through FFI with [libavif](https://github.com/AOMediaCodec/libavif)
  and [dav1d](https://code.videolan.org/videolan/dav1d), the fastest AV1
  decoder, including its hand-written SIMD assembly (NEON on Arm,
  SSE/AVX2/AVX-512 on x86). The YUV to RGB conversion uses
  [libyuv](https://chromium.googlesource.com/libyuv/libyuv/).
* **Web**: images are decoded by the browser, which supports AVIF natively.

The native code is compiled from source by a
[build hook](https://docs.flutter.dev/platform-integration/bind-native-code),
so there is no CocoaPods, Gradle or CMake plugin code and nothing to
configure.

## Usage

```dart
import 'package:avif_image_provider/avif_image_provider.dart';

// From the asset bundle.
Image(image: AssetAvifImage('assets/animation.avif'));

// From the network.
Image(image: NetworkAvifImage('https://example.com/image.avif'));

// From a file (not available on the web).
Image(image: FileAvifImage(File('/path/to/image.avif')));

// From memory.
Image(image: MemoryAvifImage(bytes));
```

The providers work everywhere an `ImageProvider` is accepted (`Image`,
`DecorationImage`, `precacheImage`, `CircleAvatar`, ...). Animated images play
automatically, honoring the frame durations and the repetition count of the
file.

### Resizing

Decoding at a smaller size saves memory and time. `ResizeImage` (and therefore
`cacheWidth`/`cacheHeight`) is supported; on native platforms the image is
downscaled before it is converted to RGBA:

```dart
Image(image: ResizeImage(AssetAvifImage('assets/photo.avif'), width: 300));
```

### Codec

To decode an image without an `ImageProvider`, use `instantiateAvifCodec`:

```dart
final codec = await instantiateAvifCodec(
  bytes,
  getTargetSize: (width, height) => TargetImageSize(width: width ~/ 2),
);
final frame = await codec.getNextFrame();
```

### Other formats

Images that are not AVIF (or HEIF/MP4) files are passed on to Flutter's own
decoders, so the providers can also be used when the format of an image is not
known in advance.

## Features

| Feature                                    | Native | Web                |
| ------------------------------------------ | ------ | ------------------ |
| Still images                               | ✅      | ✅                  |
| Animated images (image sequences)          | ✅      | ✅ <sup>1</sup>     |
| Transparency                               | ✅      | ✅                  |
| 8, 10 and 12 bit depth                     | ✅      | ✅                  |
| Crop, rotation and mirroring (`clap`, `irot`, `imir`) | ✅ | ✅           |
| `ResizeImage` / `cacheWidth`               | ✅      | ✅ (no upscaling)   |
| Decoding off the UI thread                 | ✅      | ✅ (by the browser) |

<sup>1</sup> Animations require the
[`ImageDecoder` API](https://developer.mozilla.org/en-US/docs/Web/API/ImageDecoder),
available in Chromium-based browsers and Firefox. Other browsers show the first
frame.

Like the rest of Flutter on native platforms, decoded images are 8-bit sRGB:
color profiles (ICC) and HDR gain maps are ignored, and HDR content is not tone
mapped.

## How it works

On native platforms the decoder parses the file and decodes each frame in a
background isolate, so decoding never blocks the UI thread. dav1d decodes the
AV1 data into YUV planes; libavif crops and (if requested) downscales them and
converts them to premultiplied RGBA with libyuv; rotation and mirroring are
applied with libyuv. The frames are handed to the engine with
`ImageDescriptor.raw`. Small images are decoded with a single thread (which is
faster for them), larger ones with up to one thread per CPU core.

On the web, still images are decoded with `createImageBitmap` and animated ones
with Flutter's regular image decoding (the browser's `ImageDecoder`). Flutter
cannot be used for still AVIF images because Chromium's `ImageDecoder` fails to
decode them with the `preferAnimation` option that Flutter always sets.

## Platform requirements

The build hook compiles about 140 C/C++ files in parallel; the first build
takes about a minute (per architecture) and is cached afterwards.

| Platform | Requirements                                         |
| -------- | ---------------------------------------------------- |
| Android  | Android NDK (installed automatically by Gradle)       |
| iOS      | Xcode                                                |
| macOS    | Xcode                                                |
| Linux    | Clang (already required by Flutter)                  |
| Windows  | Visual Studio 2022 with C++ (already required by Flutter) |
| All x86  | [nasm](https://www.nasm.us/) 2.14+ (recommended)     |

dav1d's x86 SIMD assembly is written for nasm. If nasm is not installed, the
decoder is built without it for x86 targets (desktop PCs, Intel Macs, Android
emulators) and is several times slower; the build prints a warning. Install it
with `brew install nasm`, `sudo apt install nasm`, `winget install NASM.NASM` or
`choco install nasm`. Arm targets (phones, Apple silicon) need nothing extra.

### Build options

The build can be configured with
[user-defines](https://dart.dev/tools/hooks#user-defines) in the
`pubspec.yaml` of your app:

```yaml
hooks:
  user_defines:
    avif_image_provider:
      # Path to nasm, if it is not on the PATH.
      nasm: C:\tools\nasm\nasm.exe
      # Disable the SIMD assembly (for debugging).
      enable_asm: false
      # Number of parallel compiler processes (defaults to the CPU count).
      jobs: 4
```

The `NASM` environment variable can also be used to point to nasm. After
installing nasm, run `flutter clean` so the library is built again with it.

## Development

* `tool/update_third_party.sh` re-vendors libavif, dav1d and libyuv into
  `third_party/` (versions are listed in `third_party/VERSIONS`).
* `dart run tool/ffigen.dart` regenerates the FFI bindings from
  `src/avif_image_provider.h`.
* `tool/generate_test_images.py` regenerates the test images (requires
  Pillow).
* `flutter test` runs the unit tests with the native decoder, and
  `flutter test --platform chrome [--wasm]` with the browser's decoder.
* `example/integration_test` contains the integration tests, which CI runs on
  Android, iOS, macOS, Linux, Windows and the web.

## License

MIT. The bundled libraries are licensed under the BSD 2-Clause
(libavif, dav1d) and BSD 3-Clause (libyuv) licenses; see `third_party/`.
