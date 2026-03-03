import 'dart:io';

import 'package:logger/logger.dart';

final _log = Logger(printer: PrettyPrinter(methodCount: 0));

/// Reads key=value pairs from a `.env` file at the project root.
///
/// Looks for `.env` in two locations:
///   1. Development: `<cwd>/.env`
///   2. Production: `<exe_dir>/.env`
class EnvConfig {
  EnvConfig._();

  static final Map<String, String> _values = {};

  /// Load the .env file. Call once at startup.
  static Future<void> load() async {
    final paths = [
      '${Directory.current.path}${Platform.pathSeparator}.env',
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}.env',
    ];

    for (final path in paths) {
      final file = File(path);
      if (await file.exists()) {
        _log.i('Loading .env from $path');
        final lines = await file.readAsLines();
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
          final eqIndex = trimmed.indexOf('=');
          if (eqIndex <= 0) continue;
          final key = trimmed.substring(0, eqIndex).trim();
          final value = trimmed.substring(eqIndex + 1).trim();
          _values[key] = value;
        }
        _log.i('Loaded ${_values.length} env variable(s).');
        return;
      }
    }

    _log.d('No .env file found (checked ${paths.length} locations).');
  }

  /// Get a value by key, or null if not set.
  static String? get(String key) => _values[key];
}
