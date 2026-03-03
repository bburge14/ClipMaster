import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';

import 'api_key_service.dart';

final _log = Logger(printer: PrettyPrinter(methodCount: 0));

/// Metadata about an available update.
class UpdateInfo {
  final String version;
  final String? downloadUrl; // null if no installer asset found
  final String releaseNotes;
  final String htmlUrl; // link to the release page on GitHub
  final int sizeBytes;
  final DateTime publishedAt;

  UpdateInfo({
    required this.version,
    this.downloadUrl,
    required this.releaseNotes,
    required this.htmlUrl,
    this.sizeBytes = 0,
    required this.publishedAt,
  });

  bool get hasInstaller => downloadUrl != null;

  /// Compare version strings like "1.0.42".
  /// Handles non-numeric suffixes gracefully (e.g. "1.0.0-beta" -> [1, 0, 0]).
  bool isNewerThan(String currentVersion) {
    final current = _parseVersion(currentVersion);
    final remote = _parseVersion(version);
    for (var i = 0; i < 3; i++) {
      final c = i < current.length ? current[i] : 0;
      final r = i < remote.length ? remote[i] : 0;
      if (r > c) return true;
      if (r < c) return false;
    }
    return false;
  }

  static List<int> _parseVersion(String v) {
    // Strip everything after a hyphen: "1.0.3-beta" -> "1.0.3"
    final clean = v.split('-').first;
    return clean.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  }
}

/// Auto-update service that checks GitHub Releases for new versions.
///
/// How it works:
///   - Every push to main triggers GitHub Actions, which builds a new
///     installer and publishes it as a GitHub Release (v1.0.1, v1.0.2, ...).
///   - On app launch, this service hits the GitHub Releases API and compares
///     the latest release version to [currentVersion].
///   - If newer, a purple banner appears. Click "Update Now" to download
///     and install the new version automatically.
///
/// [currentVersion] is stamped by CI at build time — you never edit it manually.
class AutoUpdater {
  // CI overwrites this line at build time with the real build number.
  // e.g. "1.0.42" where 42 is the GitHub Actions run_number.
  static const String currentVersion = '1.0.0';

  static const String _repoOwner = 'bburge14';
  static const String _repoName = 'ClipMaster';

  /// Read the version baked into this build.
  /// Prefers version.txt (written by CI) if present next to the exe,
  /// falls back to the hardcoded [currentVersion].
  static String getInstalledVersion() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final versionFile =
          File('$exeDir${Platform.pathSeparator}version.txt');
      if (versionFile.existsSync()) {
        return versionFile.readAsStringSync().trim();
      }
    } catch (_) {}
    return currentVersion;
  }

  /// Check GitHub Releases for a newer version.
  ///
  /// If the repo is private, pass a [githubToken] (Personal Access Token)
  /// so the API call can authenticate. Without it, private repos return 404.
  Future<UpdateInfo?> checkForUpdate({String? githubToken}) async {
    try {
      final installedVersion = getInstalledVersion();
      _log.i('Checking for updates (installed: $installedVersion)...');

      final uri = Uri.parse(
        'https://api.github.com/repos/$_repoOwner/$_repoName/releases/latest',
      );
      final headers = <String, String>{
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'ClipMasterPro/$installedVersion',
      };
      if (githubToken != null && githubToken.isNotEmpty) {
        headers['Authorization'] = 'Bearer $githubToken';
        _log.d('Using GitHub token for authenticated release check.');
      }
      final response = await http.get(uri, headers: headers);

      if (response.statusCode == 404 && (githubToken == null || githubToken.isEmpty)) {
        _log.w(
          'Update check returned 404. The repo may be private. '
          'Add a GitHub Personal Access Token in API Keys to enable updates.',
        );
        return null;
      }

      if (response.statusCode != 200) {
        _log.w('Update check failed: HTTP ${response.statusCode}');
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final tagName = (data['tag_name'] as String?) ?? '';
      if (tagName.isEmpty) {
        _log.w('Release has no tag_name');
        return null;
      }

      // Strip leading 'v': "v1.0.42" -> "1.0.42"
      final version =
          tagName.startsWith('v') ? tagName.substring(1) : tagName;

      final htmlUrl = (data['html_url'] as String?) ??
          'https://github.com/$_repoOwner/$_repoName/releases/latest';

      // Try to find an installer asset. Check multiple patterns:
      //   1. *Setup*.exe (Inno Setup convention)
      //   2. *.exe (any Windows executable)
      //   3. *.msi (Windows installer package)
      final assets = (data['assets'] as List<dynamic>?) ?? [];
      final typedAssets = assets.cast<Map<String, dynamic>>();

      Map<String, dynamic>? installerAsset;
      // Priority 1: Setup exe
      installerAsset ??= typedAssets.where((a) {
        final name = (a['name'] as String?) ?? '';
        return name.endsWith('.exe') && name.toLowerCase().contains('setup');
      }).firstOrNull;
      // Priority 2: Any exe
      installerAsset ??= typedAssets.where((a) {
        final name = (a['name'] as String?) ?? '';
        return name.endsWith('.exe');
      }).firstOrNull;
      // Priority 3: Any msi
      installerAsset ??= typedAssets.where((a) {
        final name = (a['name'] as String?) ?? '';
        return name.endsWith('.msi');
      }).firstOrNull;

      if (installerAsset != null) {
        _log.d('Found installer asset: ${installerAsset['name']}');
      } else {
        _log.d('No installer asset in release $version (banner will link to GitHub)');
      }

      final info = UpdateInfo(
        version: version,
        downloadUrl: installerAsset != null
            ? installerAsset['browser_download_url'] as String
            : null,
        releaseNotes: (data['body'] as String?) ?? '',
        htmlUrl: htmlUrl,
        sizeBytes: (installerAsset?['size'] as int?) ?? 0,
        publishedAt: DateTime.parse(data['published_at'] as String),
      );

      if (info.isNewerThan(installedVersion)) {
        _log.i('Update available: $installedVersion -> ${info.version}');
        return info;
      }

      _log.d('Already on latest ($installedVersion).');
      return null;
    } catch (e) {
      _log.e('Update check error: $e');
      return null;
    }
  }

  /// Download the installer and run it, then exit.
  ///
  /// Throws [StateError] if the release has no installer asset.
  Future<void> downloadAndInstall(
    UpdateInfo update, {
    void Function(int percent)? onProgress,
    String? githubToken,
  }) async {
    if (update.downloadUrl == null) {
      throw StateError(
        'This release has no installer. Visit the GitHub release page to '
        'download manually: ${update.htmlUrl}',
      );
    }

    final tempDir = await getTemporaryDirectory();
    final installerPath =
        '${tempDir.path}${Platform.pathSeparator}ClipMasterPro-Setup-v${update.version}.exe';
    final file = File(installerPath);

    _log.i('Downloading update to $installerPath');

    final request = http.Request('GET', Uri.parse(update.downloadUrl!));
    request.headers['Accept'] = 'application/octet-stream';
    if (githubToken != null && githubToken.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $githubToken';
    }
    final response = await http.Client().send(request);

    // Validate the response before saving — if GitHub returns an HTML
    // error page (404/302) we'd save garbage as .exe and get a
    // "16-bit application" error when trying to launch it.
    if (response.statusCode != 200) {
      // Drain the stream so the client can be cleaned up.
      await response.stream.drain<void>();
      throw StateError(
        'Download failed: HTTP ${response.statusCode}. '
        'If this is a private repo, make sure your GitHub token has '
        '"repo" scope. Release URL: ${update.htmlUrl}',
      );
    }

    final totalBytes = update.sizeBytes > 0 ? update.sizeBytes : 1;
    var receivedBytes = 0;
    final sink = file.openWrite();

    await for (final chunk in response.stream) {
      sink.add(chunk);
      receivedBytes += chunk.length;
      final percent =
          ((receivedBytes / totalBytes) * 100).clamp(0, 100).toInt();
      onProgress?.call(percent);
    }
    await sink.close();

    _log.i('Download complete. Launching installer...');

    // Write a helper script that:
    //   1. Waits for this app to close (so the exe is unlocked)
    //   2. Runs the Inno Setup installer silently
    //   3. The installer's [Run] section relaunches the app
    //   4. Cleans up the script
    final scriptPath =
        '${tempDir.path}${Platform.pathSeparator}clipmaster_update.cmd';
    await File(scriptPath).writeAsString(
      '@echo off\r\n'
      'echo Waiting for ClipMaster to close...\r\n'
      'timeout /t 3 /nobreak >nul\r\n'
      'echo Running installer...\r\n'
      '"$installerPath" /SILENT\r\n'
      'del "%~f0"\r\n',
    );

    await Process.start(
      'cmd.exe',
      ['/c', scriptPath],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }
}

/// Riverpod providers.
final autoUpdaterProvider = Provider<AutoUpdater>((ref) => AutoUpdater());

/// Holds the latest update check result. Refreshed periodically and on demand.
final updateCheckProvider =
    StateNotifierProvider<UpdateCheckNotifier, AsyncValue<UpdateInfo?>>(
  (ref) => UpdateCheckNotifier(ref),
);

/// Periodically checks for updates (every 30 minutes) and exposes the result.
class UpdateCheckNotifier extends StateNotifier<AsyncValue<UpdateInfo?>> {
  final Ref _ref;
  Timer? _timer;

  static const _checkInterval = Duration(minutes: 30);

  UpdateCheckNotifier(this._ref) : super(const AsyncValue.loading()) {
    // Check immediately on startup.
    check();
    // Then check every 30 minutes.
    _timer = Timer.periodic(_checkInterval, (_) => check());
  }

  /// Run an update check now. Called automatically on startup + periodically,
  /// and also callable from the Settings page "Check Now" button.
  Future<void> check() async {
    // Don't reset to loading if we already have a result — keeps the banner
    // visible while re-checking in the background.
    try {
      final updater = _ref.read(autoUpdaterProvider);
      // Use GitHub PAT from the API Keys service if available (needed for
      // private repos — without it the GitHub API returns 404).
      final apiKeyService = _ref.read(apiKeyServiceProvider);
      final githubToken = apiKeyService.getNextKey(LlmProvider.github);
      final result = await updater.checkForUpdate(githubToken: githubToken);
      if (mounted) state = AsyncValue.data(result);
    } catch (e, st) {
      if (mounted) state = AsyncValue.error(e, st);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
