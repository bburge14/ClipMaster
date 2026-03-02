import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Severity levels for dev console entries.
enum LogLevel { debug, info, warning, error }

/// A single entry in the dev console log.
class DevLogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String source; // e.g., "FFmpeg", "IPC", "ApiKeyService", "yt-dlp"
  final String message;
  final String? detail; // Optional stack trace or extra context.

  DevLogEntry({
    DateTime? timestamp,
    required this.level,
    required this.source,
    required this.message,
    this.detail,
  }) : timestamp = timestamp ?? DateTime.now();

  String get formatted =>
      '[${timestamp.toIso8601String().substring(11, 19)}] '
      '${level.name.toUpperCase().padRight(7)} '
      '[$source] $message';
}

/// In-app Dev Console that captures logs from all subsystems.
///
/// This provides a live, scrollable log view inside the app so the developer
/// can see exactly where an FFmpeg render or API call might be hanging,
/// without needing to open an external terminal.
///
/// Features:
///   - Circular buffer (default 2000 entries) to cap memory usage.
///   - Real-time stream for the UI to subscribe to.
///   - Filter by source, level, or text search.
///   - IPC message passthrough: all IPC messages are automatically logged.
class DevConsole {
  static const int maxEntries = 2000;

  final _entries = Queue<DevLogEntry>();
  final _controller = StreamController<DevLogEntry>.broadcast();

  /// Live stream of new log entries.
  Stream<DevLogEntry> get stream => _controller.stream;

  /// All current entries (for initial rendering of the console UI).
  List<DevLogEntry> get entries => _entries.toList();

  /// Log a message to the dev console.
  void log(
    LogLevel level,
    String source,
    String message, {
    String? detail,
  }) {
    final entry = DevLogEntry(
      level: level,
      source: source,
      message: message,
      detail: detail,
    );
    _entries.addLast(entry);
    if (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
    _controller.add(entry);
  }

  // Convenience methods.
  void debug(String source, String msg, {String? detail}) =>
      log(LogLevel.debug, source, msg, detail: detail);

  void info(String source, String msg, {String? detail}) =>
      log(LogLevel.info, source, msg, detail: detail);

  void warn(String source, String msg, {String? detail}) =>
      log(LogLevel.warning, source, msg, detail: detail);

  void error(String source, String msg, {String? detail}) =>
      log(LogLevel.error, source, msg, detail: detail);

  /// Filter entries by source, level, and/or text search.
  List<DevLogEntry> filter({
    String? source,
    LogLevel? minLevel,
    String? searchText,
  }) {
    return entries.where((e) {
      if (source != null && e.source != source) return false;
      if (minLevel != null && e.level.index < minLevel.index) return false;
      if (searchText != null &&
          !e.message.toLowerCase().contains(searchText.toLowerCase())) {
        return false;
      }
      return true;
    }).toList();
  }

  /// Get all unique source names (for the filter dropdown).
  Set<String> get sources => entries.map((e) => e.source).toSet();

  void clear() => _entries.clear();

  void dispose() => _controller.close();
}

/// Riverpod provider for the singleton DevConsole.
final devConsoleProvider = Provider<DevConsole>((ref) {
  final console = DevConsole();
  ref.onDispose(() => console.dispose());
  return console;
});
