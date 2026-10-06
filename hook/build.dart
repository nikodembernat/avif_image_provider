// Copyright 2026 The avif_image_provider authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';

import 'src/native_build.dart';

/// Builds the native AVIF decoder (libavif + dav1d + libyuv) for the target
/// platform and bundles it with the application.
///
/// See `README.md` for the user-defines that can be used to configure the
/// build.
Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    final logger = Logger.detached('avif_image_provider')
      ..level = Level.INFO
      ..onRecord.listen((record) {
        // Messages printed to stdout end up in the hook's log.
        // ignore: avoid_print
        print('[${record.level.name}] ${record.message}');
      });
    await NativeBuild(input: input, output: output, logger: logger).run();
  });
}
