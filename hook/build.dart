import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';

import 'src/native_build.dart';

/// Builds libavif + dav1d + libyuv. The README lists the user-defines that
/// configure the build.
Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    final logger = Logger.detached('avif_image_provider')
      ..level = Level.INFO
      ..onRecord.listen((record) {
        // stdout is the hook log.
        // ignore: avoid_print
        print('[${record.level.name}] ${record.message}');
      });
    await NativeBuild(input: input, output: output, logger: logger).run();
  });
}
