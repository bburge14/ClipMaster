import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/ipc/ipc_client.dart';
import 'core/logging/dev_console.dart';
import 'core/services/api_key_service.dart';
import 'core/services/auto_updater.dart';
import 'core/utils/binary_paths.dart';
import 'features/dev_console/widgets/dev_console_panel.dart';
import 'features/fact_shorts/widgets/fact_shorts_page.dart';
import 'features/timeline/widgets/magnetic_timeline.dart';
import 'features/api_keys/widgets/api_key_settings.dart';
import 'features/settings/widgets/settings_page.dart';
import 'features/viral_scout/widgets/viral_scout_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Resolve bundled binary paths (ffmpeg, yt-dlp).
  await BinaryPaths.init();

  runApp(const ProviderScope(child: ClipMasterApp()));
}

class ClipMasterApp extends ConsumerWidget {
  const ClipMasterApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'ClipMaster Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF6C5CE7),
        brightness: Brightness.dark,
      ),
      home: const MainShell(),
    );
  }
}

/// Main application shell with sidebar navigation.
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  int _selectedIndex = 0;
  bool _devConsoleVisible = false;

  @override
  void initState() {
    super.initState();
    _initServices();
  }

  Future<void> _initServices() async {
    final apiKeyService = ref.read(apiKeyServiceProvider);
    await apiKeyService.init();

    final devConsole = ref.read(devConsoleProvider);
    devConsole.info('App', 'ClipMaster Pro initialized.');
    devConsole.info('App', 'ffmpeg: ${BinaryPaths.ffmpeg}');
    devConsole.info('App', 'yt-dlp: ${BinaryPaths.ytdlp}');

    // Start the Python sidecar.
    try {
      final ipc = ref.read(ipcClientProvider);
      await ipc.start();
      devConsole.info('IPC', 'Sidecar connected.');

      // Pipe all IPC messages to the dev console.
      ipc.messages.listen((msg) {
        devConsole.debug('IPC', '${msg.type.name}: ${msg.payload}');
      });
    } catch (e) {
      devConsole.error('IPC', 'Failed to start sidecar: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final updateCheck = ref.watch(updateCheckProvider);

    return Scaffold(
      body: Column(
        children: [
          // Update notification bar
          updateCheck.when(
            data: (update) {
              if (update == null) return const SizedBox.shrink();
              return _UpdateBar(update: update);
            },
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          Expanded(
            child: Row(
              children: [
                // Sidebar navigation
                NavigationRail(
                  selectedIndex: _selectedIndex,
                  onDestinationSelected: (index) =>
                      setState(() => _selectedIndex = index),
                  labelType: NavigationRailLabelType.all,
                  leading: const Padding(
                    padding: EdgeInsets.all(8.0),
                    child: Text(
                      'CM',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  trailing: Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 16.0),
                        child: IconButton(
                          icon: Icon(
                            _devConsoleVisible
                                ? Icons.terminal
                                : Icons.terminal_outlined,
                          ),
                          tooltip: 'Dev Console',
                          onPressed: () => setState(
                            () => _devConsoleVisible = !_devConsoleVisible,
                          ),
                        ),
                      ),
                    ),
                  ),
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.movie_edit),
                      label: Text('Timeline'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.auto_awesome),
                      label: Text('Fact Shorts'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.trending_up),
                      label: Text('Scout'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.key),
                      label: Text('API Keys'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.settings),
                      label: Text('Settings'),
                    ),
                  ],
                ),
                const VerticalDivider(thickness: 1, width: 1),
                // Main content area
                Expanded(
                  child: _buildPage(),
                ),
              ],
            ),
          ),
          // Dev Console (toggle)
          if (_devConsoleVisible)
            const SizedBox(
              height: 250,
              child: DevConsolePanel(),
            ),
        ],
      ),
    );
  }

  Widget _buildPage() {
    return switch (_selectedIndex) {
      0 => const MagneticTimeline(),
      1 => const FactShortsPage(),
      2 => const ViralScoutPage(),
      3 => const ApiKeySettings(),
      4 => const SettingsPage(),
      _ => const SizedBox.shrink(),
    };
  }
}

/// Banner that appears when an update is available.
class _UpdateBar extends ConsumerStatefulWidget {
  final UpdateInfo update;
  const _UpdateBar({required this.update});

  @override
  ConsumerState<_UpdateBar> createState() => _UpdateBarState();
}

class _UpdateBarState extends ConsumerState<_UpdateBar> {
  bool _downloading = false;
  int _percent = 0;
  String? _downloadError;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: const Color(0xFF6C5CE7),
      child: Row(
        children: [
          const Icon(Icons.system_update, size: 18, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _downloadError != null
                  ? 'Update failed: $_downloadError'
                  : _downloading
                      ? 'Downloading update v${widget.update.version}... $_percent%'
                      : 'Update available: v${widget.update.version} '
                          '(current: v${AutoUpdater.getInstalledVersion()})',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          if (_downloading)
            SizedBox(
              width: 120,
              child: LinearProgressIndicator(
                value: _percent / 100,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation(Colors.white),
              ),
            )
          else if (widget.update.hasInstaller)
            TextButton(
              onPressed: _startUpdate,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: Colors.white24,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              ),
              child: const Text('Update Now'),
            )
          else
            TextButton(
              onPressed: () => _openUrl(widget.update.htmlUrl),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: Colors.white24,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              ),
              child: const Text('View on GitHub'),
            ),
        ],
      ),
    );
  }

  Future<void> _startUpdate() async {
    setState(() {
      _downloading = true;
      _downloadError = null;
    });
    try {
      final updater = ref.read(autoUpdaterProvider);
      await updater.downloadAndInstall(
        widget.update,
        onProgress: (p) => setState(() => _percent = p),
      );
    } catch (e) {
      setState(() {
        _downloading = false;
        _downloadError = e.toString();
      });
    }
  }

  void _openUrl(String url) {
    // Open the release page in the default browser.
    if (Platform.isWindows) {
      Process.run('start', [url], runInShell: true);
    } else if (Platform.isMacOS) {
      Process.run('open', [url]);
    } else {
      Process.run('xdg-open', [url]);
    }
  }
}

