// Copyright 2026 The avif_image_provider authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

import 'dav1d_config.dart';
import 'sources.dart';

/// The asset id of the native library, relative to the package.
const assetName = 'src/ffi/avif_bindings.g.dart';

const _libraryName = 'avif_image_provider';

/// How dav1d's SIMD assembly is built.
enum AsmMode() {
  /// No assembly; the (much slower) C fallbacks are used.
  none,

  /// GNU assembler syntax (`.S`), assembled by Clang. Used for Arm.
  gas,

  /// NASM syntax (`.asm`), assembled by `nasm`. Used for x86.
  nasm,
}

/// A set of sources compiled with the same options.
class CompileGroup({
  required final String name,
  required final List<Uri> sources,
  required final List<Uri> includes,
  final Map<String, String?> defines = const {},
  final List<String> flags = const [],
  final Language language = Language.c,
});

/// Builds `libavif_image_provider` from the vendored sources.
///
/// `native_toolchain_c` compiles all sources of a [CBuilder] sequentially with
/// the same flags. dav1d and libyuv need per-file flags, and compiling ~300
/// files sequentially is slow, so the sources are split into chunks that are
/// compiled in parallel into object files, which are then linked together.
class NativeBuild({
  required final BuildInput input,
  required final BuildOutputBuilder output,
  required final Logger logger,
}) {
  CodeConfig get _code => input.config.code;
  OS get _os => _code.targetOS;
  Architecture get _arch => _code.targetArchitecture;
  bool get _msvc => _os == OS.windows;
  bool get _apple => _os == OS.macOS || _os == OS.iOS;

  Uri get _thirdParty => input.packageRoot.resolve('third_party/');
  Uri get _dav1d => _thirdParty.resolve('dav1d/');
  Uri get _libavif => _thirdParty.resolve('libavif/');
  Uri get _libyuv => _thirdParty.resolve('libyuv/');
  Uri get _src => input.packageRoot.resolve('src/');

  late final Uri _workDir = input.outputDirectory.resolve('work/');
  final _nasmCandidates = <Uri>[];
  late final Uri _genDir = _workDir.resolve('gen/');

  Future<void> run() async {
    if (!input.config.buildCodeAssets) {
      return;
    }
    final stopwatch = Stopwatch()..start();
    final workDir = Directory.fromUri(_workDir);
    if (workDir.existsSync()) {
      workDir.deleteSync(recursive: true);
    }
    Directory.fromUri(_genDir).createSync(recursive: true);

    final nasm = await _resolveNasm();
    final asmMode = _asmMode(nasm);
    logger.info(
      'Building $_libraryName for ${_os}_$_arch '
      '(assembly: ${asmMode.name}${nasm != null ? ' ${nasm.path}' : ''}).',
    );

    final dav1dConfig = Dav1dConfig(
      os: _os,
      architecture: _arch,
      asm: asmMode != AsmMode.none,
      msvc: _msvc,
      version: _dav1dVersion(),
    );
    _writeGenerated('config.h', dav1dConfig.configH);
    _writeGenerated('vcs_version.h', dav1dConfig.vcsVersionH);
    if (asmMode == AsmMode.nasm) {
      _writeGenerated('config.asm', dav1dConfig.configAsm);
    }

    final groups = _compileGroups(asmMode);
    final jobs = _jobs();
    final tasks = <Future<List<Uri>> Function()>[
      for (final chunk in _chunk(groups, jobs)) () => _compileChunk(chunk),
      if (asmMode == AsmMode.nasm)
        for (final source in dav1dNasmSources(_dav1d))
          () async => [await _assemble(nasm!, dav1dConfig, source)],
    ];
    final objects = (await _runPool(tasks, jobs)).expand((e) => e).toList();
    logger.info(
      'Compiled ${objects.length} objects in ${stopwatch.elapsed} '
      'using $jobs jobs.',
    );

    await _link(objects);
    _addDependencies();
    logger.info('Built $_libraryName in ${stopwatch.elapsed}.');
  }

  /// Number of compilations to run in parallel.
  int _jobs() {
    final define = input.userDefines['jobs'];
    if (define is int && define > 0) {
      return define;
    }
    return math.max(1, Platform.numberOfProcessors);
  }

  String _dav1dVersion() {
    final versions = File.fromUri(_thirdParty.resolve('VERSIONS'));
    for (final line in versions.readAsLinesSync()) {
      final parts = line.split(' ');
      if (parts.length == 2 && parts[0] == 'dav1d') {
        return parts[1];
      }
    }
    throw StateError('dav1d version missing from ${versions.path}.');
  }

  void _writeGenerated(String name, String contents) {
    File.fromUri(_genDir.resolve(name)).writeAsStringSync(contents);
  }

  AsmMode _asmMode(File? nasm) {
    final enabled = input.userDefines['enable_asm'];
    if (enabled == false) {
      return AsmMode.none;
    }
    switch (_arch) {
      case Architecture.x64 || Architecture.ia32:
        if (nasm != null) {
          return AsmMode.nasm;
        }
        logger.warning(
          'nasm (2.14 or newer) was not found, so the AVIF decoder is built '
          'without SIMD optimizations and will be several times slower. '
          'Install nasm and make sure it is on the PATH, or set the "nasm" '
          'user-define in pubspec.yaml to its location.',
        );
        return AsmMode.none;
      case Architecture.arm64 || Architecture.arm:
        // MSVC cannot assemble GNU assembler syntax.
        return _msvc ? AsmMode.none : AsmMode.gas;
      default:
        return AsmMode.none;
    }
  }

  /// Finds a usable `nasm` executable for x86 targets.
  Future<File?> _resolveNasm() async {
    if (_arch != Architecture.x64 && _arch != Architecture.ia32) {
      return null;
    }
    final candidates = <String>[];
    final defined = input.userDefines.path('nasm');
    if (defined != null) {
      candidates.add(defined.toFilePath());
    }
    final environment = Platform.environment['NASM'];
    if (environment != null && environment.isNotEmpty) {
      candidates.add(environment);
    }
    final executable = Platform.isWindows ? 'nasm.exe' : 'nasm';
    final separator = Platform.isWindows ? ';' : ':';
    final path = Platform.environment['PATH'] ?? '';
    candidates.addAll([
      for (final directory in path.split(separator))
        if (directory.isNotEmpty)
          '$directory${Platform.pathSeparator}$executable',
      // Common install locations that are not always on the PATH (e.g. when
      // building from Xcode or Visual Studio).
      if (Platform.isMacOS) ...[
        '/opt/homebrew/bin/nasm',
        '/usr/local/bin/nasm',
        '/opt/local/bin/nasm',
      ],
      if (Platform.isWindows) ...[
        r'C:\Program Files\NASM\nasm.exe',
        r'C:\Program Files (x86)\NASM\nasm.exe',
        if (Platform.environment['LOCALAPPDATA'] case final local?)
          '$local\\bin\\NASM\\nasm.exe',
        r'C:\ProgramData\chocolatey\bin\nasm.exe',
      ],
      if (Platform.isLinux) '/usr/bin/nasm',
    ]);

    // Installing (or updating) nasm later must trigger a rebuild, so every
    // location that was looked at is a dependency, whether it exists or not.
    _nasmCandidates.addAll(candidates.map(Uri.file));
    for (final candidate in candidates) {
      final file = File(candidate);
      if (!file.existsSync()) {
        continue;
      }
      try {
        final result = await Process.run(file.path, ['-v']);
        final match = RegExp(r'version (\d+)\.(\d+)')
            .firstMatch(result.stdout.toString());
        if (result.exitCode != 0 || match == null) {
          continue;
        }
        final major = int.parse(match.group(1)!);
        final minor = int.parse(match.group(2)!);
        if (major > 2 || (major == 2 && minor >= 14)) {
          return file;
        }
        logger.warning('Ignoring ${file.path}: nasm 2.14 or newer is needed.');
      } on ProcessException {
        continue;
      }
    }
    return null;
  }

  List<String> get _commonFlags => _msvc
      ? const ['/Gy', '/Gw', '/utf-8']
      : const ['-fvisibility=hidden', '-ffunction-sections', '-fdata-sections'];

  /// Flags that silence warnings in third-party code.
  List<String> get _quiet => _msvc ? const ['/w'] : const ['-w'];

  List<CompileGroup> _compileGroups(AsmMode asmMode) {
    final asm = asmMode != AsmMode.none;
    final groups = <CompileGroup>[];

    // dav1d.
    final dav1dIncludes = [
      _genDir,
      _dav1d,
      _dav1d.resolve('include/'),
      _dav1d.resolve('include/dav1d/'),
      if (_msvc) _dav1d.resolve('include/compat/msvc/'),
    ];
    final dav1dFlags = [
      ..._commonFlags,
      ..._quiet,
      if (!_msvc) ...[
        '-fomit-frame-pointer',
        '-ffast-math',
        if (_arch == Architecture.arm64 || _arch == Architecture.arm)
          '-fno-align-functions',
      ],
    ];
    final dav1dDefines = <String, String?>{
      if (_os == OS.linux || _os == OS.android) '_GNU_SOURCE': null,
    };
    final templateDir = _genDir.resolve('dav1d_tmpl/');
    Directory.fromUri(templateDir).createSync(recursive: true);
    final templates = <Uri>[];
    for (final bitDepth in [8, 16]) {
      for (final template in dav1dTemplateSources(_dav1d)) {
        final name = template.pathSegments.last.replaceFirst(
          '.c',
          '_$bitDepth.c',
        );
        final wrapper = templateDir.resolve(name);
        File.fromUri(wrapper).writeAsStringSync(
          '// Generated by avif_image_provider/hook/build.dart.\n'
          '#define BITDEPTH $bitDepth\n'
          '#include "${template.toFilePath().replaceAll(r'\', '/')}"\n',
        );
        templates.add(wrapper);
      }
    }
    groups.add(
      CompileGroup(
        name: 'dav1d',
        sources: [
          ...dav1dSources(_dav1d),
          ...templates,
          if (_os == OS.windows) _dav1d.resolve('src/win32/thread.c'),
          if (asm && (_arch == Architecture.arm64 || _arch == Architecture.arm))
            _dav1d.resolve('src/arm/cpu.c'),
          if (asm && (_arch == Architecture.x64 || _arch == Architecture.ia32))
            _dav1d.resolve('src/x86/cpu.c'),
          if (asmMode == AsmMode.gas) ...dav1dGasSources(_dav1d, _arch),
        ],
        includes: dav1dIncludes,
        defines: dav1dDefines,
        flags: dav1dFlags,
      ),
    );

    // libavif and the wrapper.
    final avifIncludes = [
      _libavif.resolve('include/'),
      _dav1d.resolve('include/'),
      _libyuv.resolve('include/'),
    ];
    final avifDefines = <String, String?>{
      'AVIF_CODEC_DAV1D': '1',
      'AVIF_LIBYUV_ENABLED': '1',
      if (_msvc) ...{
        '_CRT_SECURE_NO_WARNINGS': null,
        '_CRT_NONSTDC_NO_WARNINGS': null,
      },
    };
    groups
      ..add(
        CompileGroup(
          name: 'libavif',
          sources: libavifSources(_libavif),
          includes: avifIncludes,
          defines: avifDefines,
          flags: [..._commonFlags, ..._quiet],
        ),
      )
      ..add(
        CompileGroup(
          name: 'wrapper',
          sources: [_src.resolve('avif_image_provider.c')],
          includes: [...avifIncludes, _src],
          defines: avifDefines,
          flags: [
            ..._commonFlags,
            if (_msvc) '/W3' else ...['-Wall', '-Wextra'],
          ],
        ),
      );

    // libyuv.
    final yuvDefines = <String, String?>{
      'LIBYUV_DISABLE_SME': null,
      if (_apple || _msvc) 'LIBYUV_DISABLE_SVE': null,
      if (_arch == Architecture.arm && !_msvc) 'LIBYUV_NEON': '1',
      if (_msvc) '_CRT_SECURE_NO_WARNINGS': null,
    };
    final yuvFlags = [
      ..._commonFlags,
      ..._quiet,
      if (_msvc) '/EHs-c-' else ...['-fno-exceptions', '-fno-rtti'],
    ];
    CompileGroup yuvGroup(String name, List<Uri> sources, [List<String>? f]) =>
        CompileGroup(
          name: name,
          sources: sources,
          includes: [_libyuv.resolve('include/')],
          defines: yuvDefines,
          flags: [...yuvFlags, ...?f],
          language: Language.cpp,
        );
    groups.add(yuvGroup('libyuv', libyuvSources(_libyuv)));
    if (!_msvc && _arch == Architecture.arm) {
      groups.add(
        yuvGroup('libyuv_neon', libyuvNeonSources(_libyuv), ['-mfpu=neon']),
      );
    }
    if (!_msvc && _arch == Architecture.arm64) {
      groups.add(
        yuvGroup('libyuv_neon64', libyuvNeon64Sources(_libyuv), [
          '-march=armv8.2-a+dotprod+i8mm',
        ]),
      );
      if (!_apple) {
        groups.add(
          yuvGroup('libyuv_sve', libyuvSveSources(_libyuv), [
            '-march=armv8.5-a+i8mm+sve2',
          ]),
        );
      }
    }
    return groups;
  }

  /// Splits the groups into chunks of roughly equal size.
  ///
  /// Sources with the same file name never end up in the same chunk because
  /// MSVC names object files after the source file.
  List<CompileGroup> _chunk(List<CompileGroup> groups, int jobs) {
    final total = groups.fold(0, (sum, group) => sum + group.sources.length);
    final chunkSize = math.max(8, (total / (jobs * 2)).ceil());
    final chunks = <CompileGroup>[];
    for (final group in groups) {
      final count = (group.sources.length / chunkSize).ceil();
      final buckets = List.generate(count, (_) => <Uri>[]);
      final names = List.generate(count, (_) => <String>{});
      var next = 0;
      for (final source in group.sources) {
        final name = _baseName(source);
        var index = -1;
        for (var i = 0; i < buckets.length; i++) {
          final candidate = (next + i) % buckets.length;
          if (!names[candidate].contains(name)) {
            index = candidate;
            break;
          }
        }
        if (index == -1) {
          buckets.add([]);
          names.add({});
          index = buckets.length - 1;
        }
        buckets[index].add(source);
        names[index].add(name);
        next = (index + 1) % buckets.length;
      }
      for (final (i, bucket) in buckets.indexed) {
        chunks.add(
          CompileGroup(
            name: '${group.name}_$i',
            sources: bucket,
            includes: group.includes,
            defines: group.defines,
            flags: group.flags,
            language: group.language,
          ),
        );
      }
    }
    return chunks;
  }

  static String _baseName(Uri source) {
    final name = source.pathSegments.last.toLowerCase();
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// Compiles [chunk] into object files and returns them.
  Future<List<Uri>> _compileChunk(CompileGroup chunk) async {
    // Every chunk gets its own output directory, since the object files are
    // named after their index (Clang) or source file (MSVC).
    final chunkInput = BuildInput({
      ...input.json,
      'out_dir_shared': _workDir.resolve('obj/${chunk.name}/').toFilePath(),
    });
    final builder = CBuilder.library(
      name: chunk.name,
      sources: [for (final source in chunk.sources) source.toFilePath()],
      includes: [for (final include in chunk.includes) include.toFilePath()],
      defines: chunk.defines,
      flags: chunk.flags,
      language: chunk.language,
      buildModeDefine: false,
      linkModePreference: LinkModePreference.static,
    );
    await builder.run(
      input: chunkInput,
      output: BuildOutputBuilder(),
      logger: _quietLogger(),
    );
    final objectExtension = _msvc ? '.obj' : '.o';
    final objects = [
      for (final entity in Directory.fromUri(
        chunkInput.outputDirectory,
      ).listSync())
        if (entity is File && entity.path.endsWith(objectExtension)) entity.uri,
    ];
    if (objects.length != chunk.sources.length) {
      throw StateError(
        'Expected ${chunk.sources.length} objects for ${chunk.name}, '
        'found ${objects.length}.',
      );
    }
    return objects;
  }

  Future<Uri> _assemble(File nasm, Dav1dConfig config, Uri source) async {
    final objectDir = _workDir.resolve('obj/nasm/');
    Directory.fromUri(objectDir).createSync(recursive: true);
    final object = objectDir.resolve(
      '${_baseName(source)}${_msvc ? '.obj' : '.o'}',
    );
    final result = await Process.run(nasm.path, [
      '-f',
      config.nasmFormat,
      '-I',
      _withTrailingSeparator(_dav1d.resolve('src/').toFilePath()),
      '-I',
      _withTrailingSeparator(_genDir.toFilePath()),
      source.toFilePath(),
      '-o',
      object.toFilePath(),
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        nasm.path,
        [source.toFilePath()],
        '${result.stdout}\n${result.stderr}',
        result.exitCode,
      );
    }
    return object;
  }

  static String _withTrailingSeparator(String path) =>
      path.endsWith(Platform.pathSeparator) || path.endsWith('/')
      ? path
      : '$path${Platform.pathSeparator}';

  /// Links all [objects] into the shared library and registers it as asset.
  Future<void> _link(List<Uri> objects) async {
    final builder = CBuilder.library(
      name: _libraryName,
      assetName: assetName,
      sources: [for (final object in objects) object.toFilePath()],
      libraries: switch (_os) {
        OS.linux => const ['m', 'dl', 'pthread'],
        OS.android => const ['m', 'dl'],
        _ => const [],
      },
      flags: switch (_os) {
        OS.linux || OS.android => const ['-Wl,--gc-sections', '-Wl,-O1'],
        OS.macOS || OS.iOS => const ['-Wl,-dead_strip'],
        _ => const [],
      },
      buildModeDefine: false,
      linkModePreference: LinkModePreference.dynamic,
    );
    // The object files are intermediate build products; they must not be
    // reported as dependencies, so the CBuilder output is discarded.
    await builder.run(
      input: input,
      output: BuildOutputBuilder(),
      logger: _quietLogger(),
    );
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: assetName,
        linkMode: DynamicLoadingBundled(),
        file: input.outputDirectory.resolve(
          _os.libraryFileName(_libraryName, DynamicLoadingBundled()),
        ),
      ),
    );
  }

  void _addDependencies() {
    final roots = [_thirdParty, _src];
    output.dependencies.addAll([
      ..._nasmCandidates,
      for (final root in roots)
        for (final entity in Directory.fromUri(root).listSync(recursive: true))
          if (entity is File) entity.uri,
    ]);
  }

  /// A logger that only forwards errors (such as compiler errors), keeping the
  /// hook output readable (the compiler command lines are very long).
  Logger _quietLogger() {
    final child = Logger.detached('cbuilder')..level = Level.ALL;
    child.onRecord.listen((record) {
      if (record.level >= Level.SEVERE) {
        logger.log(record.level, record.message);
      } else {
        logger.fine(record.message);
      }
    });
    return child;
  }
}

/// Runs [tasks] with at most [concurrency] of them running at the same time.
Future<List<T>> _runPool<T>(
  List<Future<T> Function()> tasks,
  int concurrency,
) async {
  final results = List<T?>.filled(tasks.length, null);
  final queue = Queue.of(tasks.indexed);
  Future<void> worker() async {
    while (queue.isNotEmpty) {
      final (index, task) = queue.removeFirst();
      results[index] = await task();
    }
  }

  await Future.wait([
    for (var i = 0; i < math.min(concurrency, tasks.length); i++) worker(),
  ]);
  return results.cast<T>();
}
