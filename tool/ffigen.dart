// Regenerates lib/src/ffi/avif_bindings.g.dart: dart run tool/ffigen.dart

import 'dart:io';

import 'package:ffigen/ffigen.dart';

Future<void> main() async {
  final packageRoot = Platform.script.resolve('../');
  final header = packageRoot.resolve('src/avif_image_provider.h');
  await FfiGenerator(
    output: Output(
      dart: DartOutput(
        path: packageRoot.resolve('lib/src/ffi/avif_bindings.g.dart'),
      ),
    ),
    input: Input(entryPoints: [header], include: (uri) => uri == header),
    visitors: [
      Visitor(
        func: (node) => node.isIncluded = _isOwn(node.originalName),
        struct: (node) => node.isIncluded = _isOwn(node.originalName),
        unnamedEnumConstant: (node) =>
            node.isIncluded = _isOwn(node.originalName),
      ),
    ],
  ).generate();
}

bool _isOwn(String name) => name.toLowerCase().startsWith('avifip');
