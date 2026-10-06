// Copyright 2026 The avif_image_provider authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

export 'avif_codec_native.dart'
    if (dart.library.js_interop) 'avif_codec_web.dart';
