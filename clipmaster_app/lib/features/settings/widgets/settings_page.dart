import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/ipc/ipc_client.dart';
import '../../../core/services/account_service.dart';
import '../../../core/services/api_key_service.dart';
import '../../../core/services/auto_updater.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: ListView(
        children: [
          Row(
            children: [
              const Icon(Icons.settings, size: 28, color: Color(0xFF6C5CE7)),
              const SizedBox(width: 12),
              Text('Settings', style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
              )),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Manage API keys, updates, and application preferences.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white.withOpacity(0.4),
            ),
          ),
          const SizedBox(height: 28),
          const _ConnectedAccountsSection(),
          const SizedBox(height: 20),
          const _ApiKeySection(),
          const SizedBox(height: 20),
          const _StorageSection(),
          const SizedBox(height: 20),
          const _UpdateSection(),
          const SizedBox(height: 20),
          const _SidecarStatusSection(),
          const SizedBox(height: 20),
          const _AboutSection(),
        ],
      ),
    );
  }
}

// ───────────────────── API Key Management ─────────────────────

class _ApiKeySection extends ConsumerStatefulWidget {
  const _ApiKeySection();

  @override
  ConsumerState<_ApiKeySection> createState() => _ApiKeySectionState();
}

class _ApiKeySectionState extends ConsumerState<_ApiKeySection> {
  final _keyController = TextEditingController();
  LlmProvider _selectedProvider = LlmProvider.openai;

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final apiService = ref.watch(apiKeyServiceProvider);

    return _SettingsCard(
      icon: Icons.vpn_key_rounded,
      title: 'API Keys',
      subtitle: 'Keys are encrypted and stored locally. '
          'ClipMaster uses round-robin load balancing across all healthy keys.',
      children: [
        // Add key form
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.03),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withOpacity(0.06)),
          ),
          child: Row(
            children: [
              // Provider dropdown
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.04),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<LlmProvider>(
                    value: _selectedProvider,
                    dropdownColor: const Color(0xFF1E1E2E),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    items: LlmProvider.values.map((p) {
                      return DropdownMenuItem(
                        value: p,
                        child: Text(_providerLabel(p)),
                      );
                    }).toList(),
                    onChanged: (p) => setState(() => _selectedProvider = p!),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: TextField(
                    controller: _keyController,
                    obscureText: true,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      hintText: 'Paste API key...',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                height: 40,
                child: FilledButton.icon(
                  onPressed: () async {
                    final key = _keyController.text.trim();
                    if (key.isEmpty) return;
                    await apiService.addKey(_selectedProvider, key);
                    _keyController.clear();
                    setState(() {});
                  },
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Key list per provider
        ...LlmProvider.values.map((provider) {
          final keys = apiService.getKeysForProvider(provider);
          if (keys.isEmpty) return const SizedBox.shrink();
          return _buildProviderKeys(provider, keys, apiService);
        }),
        // Empty state
        if (LlmProvider.values.every(
            (p) => apiService.getKeysForProvider(p).isEmpty))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    size: 16, color: Colors.white.withOpacity(0.3)),
                const SizedBox(width: 8),
                Text(
                  'No API keys configured. Add a key above to get started.',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withOpacity(0.3),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildProviderKeys(
    LlmProvider provider,
    List<ApiKeyEntry> keys,
    ApiKeyService service,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: _providerColor(provider).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _providerLabel(provider),
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                      color: _providerColor(provider),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${keys.length} key${keys.length > 1 ? 's' : ''}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withOpacity(0.3),
                  ),
                ),
              ],
            ),
          ),
          ...keys.map((entry) => Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.03),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white.withOpacity(0.05)),
                ),
                child: Row(
                  children: [
                    Icon(
                      entry.isHealthy
                          ? Icons.check_circle_rounded
                          : Icons.error_rounded,
                      color: entry.isHealthy
                          ? const Color(0xFF00C853)
                          : Colors.redAccent,
                      size: 16,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      entry.masked,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'Used ${entry.usageCount}x',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withOpacity(0.3),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: Icon(Icons.close,
                            size: 16,
                            color: Colors.white.withOpacity(0.3)),
                        onPressed: () async {
                          await service.removeKey(provider, entry.masked);
                          setState(() {});
                        },
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  String _providerLabel(LlmProvider p) => switch (p) {
        LlmProvider.openai => 'OpenAI',
        LlmProvider.claude => 'Claude',
        LlmProvider.gemini => 'Gemini',
        LlmProvider.github => 'GitHub',
        LlmProvider.youtube => 'YouTube',
        LlmProvider.pexels => 'Pexels',
        LlmProvider.pixabay => 'Pixabay',
      };

  Color _providerColor(LlmProvider p) => switch (p) {
        LlmProvider.openai => const Color(0xFF10A37F),
        LlmProvider.claude => const Color(0xFFD97706),
        LlmProvider.gemini => const Color(0xFF4285F4),
        LlmProvider.github => Colors.white70,
        LlmProvider.youtube => const Color(0xFFFF0000),
        LlmProvider.pexels => const Color(0xFF05A081),
        LlmProvider.pixabay => const Color(0xFF48B648),
      };
}

// ───────────────────── Update Checker ─────────────────────

class _UpdateSection extends ConsumerWidget {
  const _UpdateSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updateState = ref.watch(updateCheckProvider);
    final currentVersion = AutoUpdater.getInstalledVersion();

    return _SettingsCard(
      icon: Icons.system_update_rounded,
      title: 'Updates',
      children: [
        Row(
          children: [
            Text('Installed version',
                style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 13)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.06),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('v$currentVersion',
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        const SizedBox(height: 14),
        updateState.when(
          data: (update) {
            if (update == null) {
              return Row(
                children: [
                  const Icon(Icons.check_circle_rounded,
                      color: Color(0xFF00C853), size: 18),
                  const SizedBox(width: 8),
                  const Text('You\'re on the latest version.',
                      style: TextStyle(fontSize: 13)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () =>
                        ref.read(updateCheckProvider.notifier).check(),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Check Now'),
                  ),
                ],
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.new_releases_rounded,
                        color: Color(0xFF6C5CE7), size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'v${update.version} available',
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                    const Spacer(),
                    if (update.hasInstaller)
                      FilledButton.icon(
                        onPressed: () => _startUpdate(context, ref, update),
                        icon: const Icon(Icons.download, size: 16),
                        label: const Text('Update Now'),
                      )
                    else
                      OutlinedButton.icon(
                        onPressed: () => _openUrl(update.htmlUrl),
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('View Release'),
                      ),
                  ],
                ),
                if (update.releaseNotes.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.03),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white.withOpacity(0.05)),
                    ),
                    child: Text(
                      update.releaseNotes,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.4),
                        height: 1.5,
                      ),
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            );
          },
          loading: () => Row(
            children: [
              SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white.withOpacity(0.3),
                  )),
              const SizedBox(width: 10),
              Text('Checking for updates...',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withOpacity(0.4),
                  )),
            ],
          ),
          error: (e, _) => Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  color: Colors.orange, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Update check failed: $e',
                  style: const TextStyle(fontSize: 12, color: Colors.orange),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton.icon(
                onPressed: () =>
                    ref.read(updateCheckProvider.notifier).check(),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _startUpdate(
      BuildContext context, WidgetRef ref, UpdateInfo update) async {
    try {
      final updater = ref.read(autoUpdaterProvider);
      final apiKeyService = ref.read(apiKeyServiceProvider);
      final githubToken = apiKeyService.getNextKey(LlmProvider.github);
      await updater.downloadAndInstall(update, githubToken: githubToken);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Update failed: $e')),
        );
      }
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

// ───────────────────── Connected Accounts ─────────────────────

class _ConnectedAccountsSection extends ConsumerStatefulWidget {
  const _ConnectedAccountsSection();

  @override
  ConsumerState<_ConnectedAccountsSection> createState() =>
      _ConnectedAccountsSectionState();
}

class _ConnectedAccountsSectionState
    extends ConsumerState<_ConnectedAccountsSection> {
  bool _connecting = false;
  String? _connectError;

  Future<void> _connect(AccountProvider provider) async {
    setState(() {
      _connecting = true;
      _connectError = null;
    });
    try {
      final accountService = ref.read(accountServiceProvider);
      await accountService.connect(provider);
      if (mounted) setState(() => _connecting = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _connectError = e.toString();
        });
      }
    }
  }

  Future<void> _disconnect(AccountProvider provider) async {
    final accountService = ref.read(accountServiceProvider);
    await accountService.disconnect(provider);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final accountService = ref.watch(accountServiceProvider);

    return _SettingsCard(
      icon: Icons.account_circle_rounded,
      title: 'Connected Accounts',
      subtitle: 'Log in to YouTube and Twitch to unlock uploads, '
          'VOD downloads, and channel analytics.',
      children: [
        _buildAccountRow(
          provider: AccountProvider.youtube,
          icon: Icons.play_circle_filled,
          label: 'YouTube',
          color: const Color(0xFFFF0000),
          account: accountService.getAccount(AccountProvider.youtube),
          hasClientId: accountService.hasClientId(AccountProvider.youtube),
        ),
        const SizedBox(height: 10),
        _buildAccountRow(
          provider: AccountProvider.twitch,
          icon: Icons.live_tv,
          label: 'Twitch',
          color: const Color(0xFF9146FF),
          account: accountService.getAccount(AccountProvider.twitch),
          hasClientId: accountService.hasClientId(AccountProvider.twitch),
        ),
        if (_connectError != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.redAccent.withOpacity(0.06),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.redAccent.withOpacity(0.15)),
            ),
            child: Text(
              _connectError!,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withOpacity(0.5),
                height: 1.4,
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.03),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Setup Instructions',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withOpacity(0.5),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'To enable account login, add OAuth Client IDs to your .env file:\n\n'
                'YouTube:\n'
                '  1. Go to console.cloud.google.com > Credentials\n'
                '  2. Create an OAuth 2.0 Client ID (Desktop type)\n'
                '  3. Add to .env: GOOGLE_CLIENT_ID=... and GOOGLE_CLIENT_SECRET=...\n\n'
                'Twitch:\n'
                '  1. Go to dev.twitch.tv/console/apps\n'
                '  2. Register a new application (use http://localhost as redirect)\n'
                '  3. Add to .env: TWITCH_CLIENT_ID=... and TWITCH_CLIENT_SECRET=...',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withOpacity(0.3),
                  height: 1.5,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAccountRow({
    required AccountProvider provider,
    required IconData icon,
    required String label,
    required Color color,
    required ConnectedAccount? account,
    required bool hasClientId,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 24, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                if (account != null)
                  Text(
                    'Connected as ${account.username}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF00C853),
                    ),
                  )
                else if (!hasClientId)
                  Text(
                    'Client ID not configured (see setup below)',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withOpacity(0.3),
                    ),
                  )
                else
                  Text(
                    'Not connected',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withOpacity(0.3),
                    ),
                  ),
              ],
            ),
          ),
          if (account != null)
            TextButton(
              onPressed: _connecting ? null : () => _disconnect(provider),
              child: const Text(
                'Disconnect',
                style: TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            )
          else
            FilledButton(
              onPressed:
                  (!hasClientId || _connecting) ? null : () => _connect(provider),
              style: FilledButton.styleFrom(
                backgroundColor: color.withOpacity(0.8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              child: _connecting
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Connect', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

// ───────────────────── Storage / Folders ─────────────────────

class _StorageSection extends StatelessWidget {
  const _StorageSection();

  @override
  Widget build(BuildContext context) {
    return _SettingsCard(
      icon: Icons.folder_rounded,
      title: 'Storage',
      subtitle: 'Where ClipMaster stores downloads, proxies, and exports.',
      children: [
        _FolderRow(
          label: 'App Data',
          description: 'Settings, API keys, account tokens',
          getPath: () async {
            final dir = await getApplicationSupportDirectory();
            return dir.path;
          },
        ),
        const SizedBox(height: 8),
        _FolderRow(
          label: 'Downloads & Exports',
          description: 'Downloaded videos, generated shorts, TTS audio',
          getPath: () async {
            final dir = await getApplicationDocumentsDirectory();
            final clipmasterDir =
                Directory('${dir.path}${Platform.pathSeparator}ClipMaster Pro');
            if (!clipmasterDir.existsSync()) {
              await clipmasterDir.create(recursive: true);
            }
            return clipmasterDir.path;
          },
        ),
        const SizedBox(height: 8),
        _FolderRow(
          label: 'Temp / Cache',
          description: 'Temporary files, update downloads',
          getPath: () async {
            final dir = await getTemporaryDirectory();
            return dir.path;
          },
        ),
      ],
    );
  }
}

class _FolderRow extends StatefulWidget {
  final String label;
  final String description;
  final Future<String> Function() getPath;

  const _FolderRow({
    required this.label,
    required this.description,
    required this.getPath,
  });

  @override
  State<_FolderRow> createState() => _FolderRowState();
}

class _FolderRowState extends State<_FolderRow> {
  String? _path;

  @override
  void initState() {
    super.initState();
    widget.getPath().then((p) {
      if (mounted) setState(() => _path = p);
    });
  }

  void _openFolder() {
    if (_path == null) return;
    if (Platform.isWindows) {
      Process.run('explorer.exe', [_path!]);
    } else if (Platform.isMacOS) {
      Process.run('open', [_path!]);
    } else {
      Process.run('xdg-open', [_path!]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.description,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withOpacity(0.3),
                  ),
                ),
                if (_path != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    _path!,
                    style: TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                      color: Colors.white.withOpacity(0.2),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            onPressed: _path != null ? _openFolder : null,
            icon: const Icon(Icons.folder_open, size: 20),
            tooltip: 'Open in file explorer',
            style: IconButton.styleFrom(
              foregroundColor: const Color(0xFF6C5CE7),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────── Sidecar Status ─────────────────────

class _SidecarStatusSection extends ConsumerWidget {
  const _SidecarStatusSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ipc = ref.watch(ipcClientProvider);
    final connected = ipc.isConnected;

    return _SettingsCard(
      icon: Icons.dns_rounded,
      title: 'Python Sidecar',
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: connected
                    ? const Color(0xFF00C853)
                    : Colors.redAccent,
                boxShadow: [
                  BoxShadow(
                    color: (connected
                            ? const Color(0xFF00C853)
                            : Colors.redAccent)
                        .withOpacity(0.4),
                    blurRadius: 6,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              connected ? 'Connected' : 'Not connected',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: connected
                    ? const Color(0xFF00C853)
                    : Colors.redAccent,
              ),
            ),
          ],
        ),
        if (!connected) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.redAccent.withOpacity(0.06),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.redAccent.withOpacity(0.15)),
            ),
            child: Text(
              'The sidecar powers Fact Shorts and Viral Scout. '
              'Run setup.bat (Windows) or setup.sh (Linux/Mac), '
              'then restart the app. Check the Dev Console for details.',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withOpacity(0.5),
                height: 1.5,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ───────────────────── About ─────────────────────

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    return _SettingsCard(
      icon: Icons.info_outline_rounded,
      title: 'About',
      children: [
        Text(
          'ClipMaster Pro',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Colors.white.withOpacity(0.7),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'AI-powered short-form video creation tool.',
          style: TextStyle(
            fontSize: 13,
            color: Colors.white.withOpacity(0.35),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            'v${AutoUpdater.getInstalledVersion()}',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: Colors.white.withOpacity(0.35),
            ),
          ),
        ),
      ],
    );
  }
}

// ───────────────────── Shared Card ─────────────────────

class _SettingsCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> children;

  const _SettingsCard({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: const Color(0xFF6C5CE7)),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withOpacity(0.3),
                ),
              ),
            ],
            Divider(
              height: 24,
              color: Colors.white.withOpacity(0.06),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}
