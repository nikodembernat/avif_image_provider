// Copyright 2026 The avif_image_provider authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Fast AVIF image providers for Flutter, with support for animated images.
///
/// ```dart
/// Image(image: AssetAvifImage('assets/animation.avif'))
/// ```
library;

export 'src/avif_exception.dart';
export 'src/avif_image_provider.dart';
export 'src/codec/avif_codec.dart' show instantiateAvifCodec;
