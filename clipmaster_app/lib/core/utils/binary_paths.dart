import 'dart:io';

import 'package:logger/logger.dart';

final _log = Logger(printer: PrettyPrinter(methodCount: 0));

/// Resolves paths to bundled binaries (ffmpeg.exe, yt-dlp.exe) using
/// relative paths within the app's installation directory.
///
/// Strategy:
///   1. In development: check project-root `bundled_binaries/`.
///   2. In production: check `<exe_dir>/bundled_binaries/`.
///   3. Fallback: check system PATH (assume user has it installed globally).
class BinaryPaths {
  BinaryPaths._();

  static String? _ffmpegPath;
  static String? _ytdlpPath;

  static String get ffmpeg => _ffmpegPath ?? 'ffmpeg';
  static String get ytdlp => _ytdlpPath ?? 'yt-dlp';

  /// Call once at app startup to resolve and cache binary paths.
  static Future<void> init() async {
    _ffmpegPath = await _resolve('ffmpeg');
    _ytdlpPath = await _resolve('yt-dlp');
    _log.i('ffmpeg resolved to: $ffmpeg');
    _log.i('yt-dlp resolved to: $ytdlp');
  }

  static Future<String?> _resolve(String binaryName) async {
    final exeName = Platform.isWindows ? '$binaryName.exe' : binaryName;

    // 1. Development path: <project_root>/bundled_binaries/
    final devPath = '${Directory.current.path}/bundled_binaries/$exeName';
    if (await File(devPath).exists()) {
      _log.d('Found $binaryName at dev path: $devPath');
      return devPath;
    }

    // 2. Production path: alongside the executable.
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final prodPath = '$exeDir/bundled_binaries/$exeName';
    if (await File(prodPath).exists()) {
      _log.d('Found $binaryName at prod path: $prodPath');
      return prodPath;
    }

    // 3. Fallback: system PATH.
    _log.w('$binaryName not found in bundled_binaries. Falling back to PATH.');
    return null;
  }

  /// Verify that a binary is functional by running `--version`.
  static Future<bool> verify(String path) async {
    try {
      final result = await Process.run(path, ['--version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
