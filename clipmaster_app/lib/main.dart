import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/ipc/ipc_client.dart';
import 'core/logging/dev_console.dart';
import 'core/services/api_key_service.dart';
import 'core/utils/binary_paths.dart';
import 'features/dev_console/widgets/dev_console_panel.dart';
import 'features/timeline/widgets/magnetic_timeline.dart';
import 'features/api_keys/widgets/api_key_settings.dart';

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
    return Scaffold(
      body: Column(
        children: [
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
      1 => const _FactShortsPlaceholder(),
      2 => const _ViralScoutPlaceholder(),
      3 => const ApiKeySettings(),
      _ => const SizedBox.shrink(),
    };
  }
}

// Placeholder widgets until full feature UIs are built.

class _FactShortsPlaceholder extends StatelessWidget {
  const _FactShortsPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: 64, color: Colors.white24),
          SizedBox(height: 16),
          Text('Fact-Shorts Generator',
              style: TextStyle(fontSize: 24, color: Colors.white38)),
          SizedBox(height: 8),
          Text('Select a category to generate engagement-optimized shorts.',
              style: TextStyle(color: Colors.white24)),
        ],
      ),
    );
  }
}

class _ViralScoutPlaceholder extends StatelessWidget {
  const _ViralScoutPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.trending_up, size: 64, color: Colors.white24),
          SizedBox(height: 16),
          Text('Viral Scout',
              style: TextStyle(fontSize: 24, color: Colors.white38)),
          SizedBox(height: 8),
          Text('Trending video discovery and analysis.',
              style: TextStyle(color: Colors.white24)),
        ],
      ),
    );
  }
}
