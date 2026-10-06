## 0.1.0

* Initial release.
* `MemoryAvifImage`, `FileAvifImage`, `AssetAvifImage` and `NetworkAvifImage`
  image providers, plus the `AvifImageProvider` base class.
* Still and animated AVIF images, with transparency, 8/10/12-bit content and
  the `clap`, `irot` and `imir` transforms.
* Native decoding with libavif 1.4.2, dav1d 1.5.4 (with SIMD assembly) and
  libyuv, built by a build hook. No CocoaPods, Gradle or CMake plugin code.
* Browser decoding on the web (JavaScript and WebAssembly).
* `ResizeImage` (`cacheWidth`/`cacheHeight`) support with native downscaling.
