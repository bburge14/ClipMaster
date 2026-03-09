import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';

import 'core/ipc/ipc_client.dart';
import 'core/ipc/ipc_message.dart';
import 'core/logging/dev_console.dart';
import 'core/services/account_service.dart';
import 'core/services/activity_service.dart';
import 'core/services/api_key_service.dart';
import 'core/services/auto_updater.dart';
import 'core/utils/binary_paths.dart';
import 'core/utils/env_config.dart';
import 'features/activity/widgets/activity_page.dart';
import 'features/dev_console/widgets/dev_console_panel.dart';
import 'features/onboarding/widgets/onboarding_wizard.dart';
import 'features/timeline/widgets/magnetic_timeline.dart';
import 'features/settings/widgets/settings_page.dart';
import 'features/viral_scout/widgets/viral_scout_page.dart';

/// Provider to allow any page to switch tabs programmatically.
final selectedTabProvider = StateProvider<int>((ref) => 0);

/// Provider to allow the dev console panel to close itself.
final devConsoleVisibleProvider = StateProvider<bool>((ref) => false);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // Load .env config (GitHub token, API keys, etc.).
  await EnvConfig.load();

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
        textTheme: GoogleFonts.interTextTheme(
          ThemeData(brightness: Brightness.dark).textTheme,
        ),
        cardTheme: CardTheme(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.white.withOpacity(0.06)),
          ),
          color: const Color(0xFF1E1E2E),
        ),
        scaffoldBackgroundColor: const Color(0xFF141420),
        dividerColor: Colors.white.withOpacity(0.06),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF6C5CE7),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white.withOpacity(0.04),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF6C5CE7)),
          ),
        ),
        chipTheme: ChipThemeData(
          backgroundColor: Colors.white.withOpacity(0.06),
          selectedColor: const Color(0xFF6C5CE7).withOpacity(0.25),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        navigationRailTheme: NavigationRailThemeData(
          backgroundColor: const Color(0xFF141420),
          selectedIconTheme: const IconThemeData(color: Color(0xFF6C5CE7)),
          selectedLabelTextStyle: const TextStyle(
            color: Color(0xFF6C5CE7),
            fontWeight: FontWeight.w600,
            fontSize: 11,
          ),
          unselectedLabelTextStyle: TextStyle(
            color: Colors.white.withOpacity(0.4),
            fontSize: 11,
          ),
          unselectedIconTheme: IconThemeData(
            color: Colors.white.withOpacity(0.4),
          ),
          indicatorColor: const Color(0xFF6C5CE7).withOpacity(0.15),
        ),
      ),
      home: const _AppEntry(),
    );
  }
}

/// Entry point that initializes API key service, then shows onboarding or main shell.
class _AppEntry extends ConsumerStatefulWidget {
  const _AppEntry();

  @override
  ConsumerState<_AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends ConsumerState<_AppEntry> {
  bool _initialized = false;
  bool _showOnboarding = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final apiKeyService = ref.read(apiKeyServiceProvider);
    await apiKeyService.init();

    // Check if any keys exist — if not, show onboarding.
    bool hasKeys = false;
    for (final p in LlmProvider.values) {
      if (apiKeyService.getKeysForProvider(p).isNotEmpty) {
        hasKeys = true;
        break;
      }
    }

    if (mounted) {
      setState(() {
        _initialized = true;
        _showOnboarding = !hasKeys;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Scaffold(
        backgroundColor: Color(0xFF141420),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_showOnboarding) {
      return OnboardingWizard(
        onComplete: () {
          setState(() => _showOnboarding = false);
        },
      );
    }

    return const MainShell();
  }
}

/// Main application shell with sidebar navigation.
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {

  @override
  void initState() {
    super.initState();
    _initServices();
  }

  Future<void> _initServices() async {
    final accountService = ref.read(accountServiceProvider);
    await accountService.init();

    final devConsole = ref.read(devConsoleProvider);
    devConsole.info('App', 'ClipMaster Pro initialized.');
    devConsole.info('App', 'ffmpeg: ${BinaryPaths.ffmpeg}');
    devConsole.info('App', 'yt-dlp: ${BinaryPaths.ytdlp}');

    // Start the Python sidecar.
    try {
      final ipc = ref.read(ipcClientProvider);
      await ipc.start();
      devConsole.info('IPC', 'Sidecar connected.');

      // Restore persisted cookie browser setting to the sidecar.
      try {
        const storage = FlutterSecureStorage();
        final savedBrowser =
            await storage.read(key: 'clipmaster_cookie_browser');
        if (savedBrowser != null && savedBrowser.isNotEmpty) {
          await ipc.send(
            IpcMessage(
              type: MessageType.setCookieBrowser,
              payload: {'browser': savedBrowser},
            ),
            timeout: const Duration(seconds: 5),
          );
          devConsole.info(
              'IPC', 'Restored cookie browser: $savedBrowser');
        }
      } catch (e) {
        devConsole.error('IPC', 'Failed to restore cookie browser: $e');
      }

      // Pipe all IPC messages to the dev console.
      ipc.messages.listen((msg) {
        devConsole.debug('IPC', '${msg.type.name}: ${msg.payload}');
      });
    } catch (e) {
      devConsole.error('IPC', 'Failed to start sidecar: $e');
    }
  }

  static const _navItems = [
    _NavItem(Icons.movie_creation_outlined, Icons.movie_creation, 'Editor'),
    _NavItem(Icons.trending_up_outlined, Icons.trending_up, 'Scout'),
    _NavItem(Icons.downloading_outlined, Icons.downloading, 'Activity'),
    _NavItem(Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final updateCheck = ref.watch(updateCheckProvider);
    final selectedIndex = ref.watch(selectedTabProvider);
    final devConsoleVisible = ref.watch(devConsoleVisibleProvider);

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
                // Sidebar
                Container(
                  width: 80,
                  color: const Color(0xFF141420),
                  child: Column(
                    children: [
                      const SizedBox(height: 20),
                      // Brand
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              const Color(0xFF6C5CE7).withOpacity(0.2),
                              const Color(0xFF6C5CE7).withOpacity(0.05),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Text(
                          'CM',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF6C5CE7),
                            letterSpacing: -0.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'PRO',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: Colors.white.withOpacity(0.3),
                          letterSpacing: 3,
                        ),
                      ),
                      const SizedBox(height: 24),
                      // Nav items
                      ...List.generate(_navItems.length, (i) {
                        final item = _navItems[i];
                        final selected = selectedIndex == i;
                        // Activity tab badge — count unseen + running tasks
                        int badge = 0;
                        if (i == 2) {
                          final tasks = ref.watch(activityProvider);
                          badge = tasks
                              .where((t) =>
                                  t.isRunning ||
                                  (!t.hasBeenSeen && !t.isRunning))
                              .length;
                        }
                        return _buildNavButton(item, selected, () {
                          ref.read(selectedTabProvider.notifier).state = i;
                        }, badge: badge);
                      }),
                      const Spacer(),
                      // Dev console toggle
                      _buildNavButton(
                        const _NavItem(
                          Icons.terminal_outlined,
                          Icons.terminal,
                          'Console',
                        ),
                        devConsoleVisible,
                        () => ref.read(devConsoleVisibleProvider.notifier).state =
                            !devConsoleVisible,
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
                Container(
                  width: 1,
                  color: Colors.white.withOpacity(0.06),
                ),
                // Main content area — IndexedStack keeps all pages alive
                // so tab state is preserved when switching.
                Expanded(
                  child: IndexedStack(
                    index: selectedIndex,
                    children: const [
                      MagneticTimeline(),
                      ViralScoutPage(),
                      ActivityPage(),
                      SettingsPage(),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Dev Console (toggle)
          if (devConsoleVisible)
            const SizedBox(
              height: 250,
              child: DevConsolePanel(),
            ),
        ],
      ),
    );
  }

  Widget _buildNavButton(
    _NavItem item,
    bool selected,
    VoidCallback onTap, {
    int badge = 0,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: selected
                  ? const Color(0xFF6C5CE7).withOpacity(0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(
                      selected ? item.activeIcon : item.icon,
                      size: 22,
                      color: selected
                          ? const Color(0xFF6C5CE7)
                          : Colors.white.withOpacity(0.4),
                    ),
                    if (badge > 0)
                      Positioned(
                        right: -8,
                        top: -6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFF6C5CE7),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          constraints: const BoxConstraints(minWidth: 16),
                          child: Text(
                            '$badge',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  item.label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    color: selected
                        ? const Color(0xFF6C5CE7)
                        : Colors.white.withOpacity(0.4),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

}

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const _NavItem(this.icon, this.activeIcon, this.label);
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
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF6C5CE7), Color(0xFF8B7CF7)],
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.system_update, size: 18, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _downloadError != null
                  ? 'Update failed: $_downloadError'
                  : _downloading
                      ? 'Downloading v${widget.update.version}... $_percent%'
                      : 'Update available: v${widget.update.version} '
                          '(current: v${AutoUpdater.getInstalledVersion()})',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (_downloading)
            SizedBox(
              width: 120,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _percent / 100,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation(Colors.white),
                ),
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
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
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
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
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
      final apiKeyService = ref.read(apiKeyServiceProvider);
      final githubToken = apiKeyService.getNextKey(LlmProvider.github);
      await updater.downloadAndInstall(
        widget.update,
        onProgress: (p) => setState(() => _percent = p),
        githubToken: githubToken,
      );
    } catch (e) {
      setState(() {
        _downloading = false;
        _downloadError = e.toString();
      });
    }
  }

  void _openUrl(String url) {
    if (Platform.isWindows) {
      Process.run('start', [url], runInShell: true);
    } else if (Platform.isMacOS) {
      Process.run('open', [url]);
    } else {
      Process.run('xdg-open', [url]);
    }
  }
}
