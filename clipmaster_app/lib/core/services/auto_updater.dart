import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';

final _log = Logger(printer: PrettyPrinter(methodCount: 0));

/// Metadata about an available update.
class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String releaseNotes;
  final int sizeBytes;
  final DateTime publishedAt;

  UpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.sizeBytes,
    required this.publishedAt,
  });

  /// Compare version strings like "1.2.3".
  bool isNewerThan(String currentVersion) {
    final current = currentVersion.split('.').map(int.parse).toList();
    final remote = version.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      final c = i < current.length ? current[i] : 0;
      final r = i < remote.length ? remote[i] : 0;
      if (r > c) return true;
      if (r < c) return false;
    }
    return false;
  }
}

/// Auto-update service that checks GitHub Releases for new versions.
///
/// Flow:
///   1. On app launch, checks the GitHub Releases API for the latest release.
///   2. If a newer version exists, shows a notification in the UI.
///   3. User clicks "Update" -> downloads the installer .exe to temp.
///   4. Launches the installer and exits the current app.
class AutoUpdater {
  static const String currentVersion = '1.0.0';
  static const String _repoOwner = 'bburge14';
  static const String _repoName = 'ClipMaster';

  /// Check GitHub Releases for a newer version.
  Future<UpdateInfo?> checkForUpdate() async {
    try {
      final uri = Uri.parse(
        'https://api.github.com/repos/$_repoOwner/$_repoName/releases/latest',
      );
      final response = await http.get(uri, headers: {
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'ClipMasterPro/$currentVersion',
      });

      if (response.statusCode != 200) {
        _log.w('Update check failed: HTTP ${response.statusCode}');
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final tagName = (data['tag_name'] as String?) ?? '';
      // Strip leading 'v' from tag: "v1.2.3" -> "1.2.3"
      final version = tagName.startsWith('v') ? tagName.substring(1) : tagName;

      // Find the .exe installer asset.
      final assets = (data['assets'] as List<dynamic>?) ?? [];
      final installerAsset = assets.cast<Map<String, dynamic>>().where(
        (a) {
          final name = (a['name'] as String?) ?? '';
          return name.endsWith('.exe') && name.contains('Setup');
        },
      ).firstOrNull;

      if (installerAsset == null) {
        _log.d('No installer asset found in release $version');
        return null;
      }

      final info = UpdateInfo(
        version: version,
        downloadUrl: installerAsset['browser_download_url'] as String,
        releaseNotes: (data['body'] as String?) ?? '',
        sizeBytes: (installerAsset['size'] as int?) ?? 0,
        publishedAt: DateTime.parse(data['published_at'] as String),
      );

      if (info.isNewerThan(currentVersion)) {
        _log.i('Update available: $currentVersion -> ${info.version}');
        return info;
      }

      _log.d('Already on latest version ($currentVersion).');
      return null;
    } catch (e) {
      _log.e('Update check error: $e');
      return null;
    }
  }

  /// Download the installer and launch it.
  Future<void> downloadAndInstall(
    UpdateInfo update, {
    void Function(int percent)? onProgress,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final installerPath =
        '${tempDir.path}${Platform.pathSeparator}ClipMasterPro-Setup-v${update.version}.exe';
    final file = File(installerPath);

    _log.i('Downloading update to $installerPath');

    // Stream download with progress.
    final request = http.Request('GET', Uri.parse(update.downloadUrl));
    final response = await http.Client().send(request);

    final totalBytes = update.sizeBytes > 0 ? update.sizeBytes : 1;
    var receivedBytes = 0;
    final sink = file.openWrite();

    await for (final chunk in response.stream) {
      sink.add(chunk);
      receivedBytes += chunk.length;
      final percent = ((receivedBytes / totalBytes) * 100).clamp(0, 100).toInt();
      onProgress?.call(percent);
    }
    await sink.close();

    _log.i('Download complete. Launching installer...');

    // Launch the installer and exit.
    await Process.start(installerPath, ['/SILENT'], mode: ProcessStartMode.detached);
    exit(0);
  }
}

/// Riverpod provider for the auto-updater.
final autoUpdaterProvider = Provider<AutoUpdater>((ref) => AutoUpdater());

/// Riverpod provider that checks for updates on read.
final updateCheckProvider = FutureProvider<UpdateInfo?>((ref) async {
  final updater = ref.read(autoUpdaterProvider);
  return updater.checkForUpdate();
});
