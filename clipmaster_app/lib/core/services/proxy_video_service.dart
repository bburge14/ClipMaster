import 'dart:io';

import 'package:logger/logger.dart';

import '../utils/binary_paths.dart';

final _log = Logger(printer: PrettyPrinter(methodCount: 0));

/// Manages the Proxy Video system for zero-lag timeline scrubbing.
///
/// Strategy:
///   - When a 4K VOD is downloaded, a 720p proxy is automatically generated.
///   - The timeline always uses the proxy for scrubbing and preview.
///   - Final renders use the original 4K source for full quality output.
///   - Proxies are stored alongside originals with a `.proxy.mp4` suffix.
class ProxyVideoService {
  /// Generate a 720p proxy from a high-resolution source video.
  ///
  /// Uses FFmpeg with fast settings optimized for editing, not quality:
  ///   - Scale to 720p height, maintain aspect ratio.
  ///   - Use ultrafast preset for speed.
  ///   - Low CRF (28) since this is just for preview.
  Future<String> generateProxy(
    String sourcePath, {
    String? outputPath,
    void Function(int percent)? onProgress,
  }) async {
    final output = outputPath ?? _proxyPath(sourcePath);
    final outputFile = File(output);

    // Skip if proxy already exists.
    if (await outputFile.exists()) {
      _log.i('Proxy already exists: $output');
      return output;
    }

    // Ensure output directory exists.
    await outputFile.parent.create(recursive: true);

    _log.i('Generating proxy: $sourcePath -> $output');

    final args = [
      '-i', sourcePath,
      '-vf', 'scale=-2:720',
      '-c:v', 'libx264',
      '-preset', 'ultrafast',
      '-crf', '28',
      '-c:a', 'aac',
      '-b:a', '128k',
      '-y', // Overwrite without asking.
      output,
    ];

    final process = await Process.start(BinaryPaths.ffmpeg, args);

    // Parse FFmpeg stderr for progress (it outputs progress there).
    final errBuffer = StringBuffer();
    process.stderr.transform(const SystemEncoding().decoder).listen((data) {
      errBuffer.write(data);
      // FFmpeg progress lines look like: "frame=  120 fps= 60 ..."
      // For a more accurate approach, use `-progress pipe:1` flag.
    });

    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      final error = errBuffer.toString();
      _log.e('FFmpeg proxy generation failed (exit $exitCode): $error');
      throw Exception('FFmpeg failed with exit code $exitCode');
    }

    _log.i('Proxy generated: $output');
    return output;
  }

  /// Get the proxy path for a given source video.
  String getProxyPath(String sourcePath) => _proxyPath(sourcePath);

  /// Check if a proxy exists for the given source.
  Future<bool> hasProxy(String sourcePath) async {
    return File(_proxyPath(sourcePath)).exists();
  }

  String _proxyPath(String sourcePath) {
    final lastDot = sourcePath.lastIndexOf('.');
    if (lastDot == -1) return '$sourcePath.proxy.mp4';
    return '${sourcePath.substring(0, lastDot)}.proxy.mp4';
  }
}
