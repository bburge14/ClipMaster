import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/ipc/ipc_client.dart';
import '../../../core/ipc/ipc_message.dart';
import '../../../core/services/account_service.dart';
import '../../../core/services/api_key_service.dart';
import '../../../core/services/auto_updater.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left column: Accounts + API Keys
          Expanded(
            flex: 3,
            child: ListView(
              children: [
                _buildHeader(context),
                const SizedBox(height: 24),
                const _ConnectedAccountsSection(),
                const SizedBox(height: 20),
                const _ApiKeySection(),
              ],
            ),
          ),
          const SizedBox(width: 24),
          // Right column: Storage, Updates, Sidecar, About
          Expanded(
            flex: 2,
            child: ListView(
              children: const [
                _StorageSection(),
                SizedBox(height: 16),
                _BrowserCookieSection(),
                SizedBox(height: 16),
                _UpdateSection(),
                SizedBox(height: 16),
                _SidecarStatusSection(),
                SizedBox(height: 16),
                _AboutSection(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        const Icon(Icons.settings, size: 28, color: Color(0xFF6C5CE7)),
        const SizedBox(width: 12),
        Text('Settings',
            style: theme.textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  API KEY MANAGEMENT — Grouped by category, with inline add + list
// ═══════════════════════════════════════════════════════════════════

const _aiProviders = [LlmProvider.openai, LlmProvider.claude, LlmProvider.gemini];
const _mediaProviders = [LlmProvider.youtube, LlmProvider.pexels, LlmProvider.pixabay];
const _platformProviders = [LlmProvider.github];

class _ApiKeySection extends ConsumerStatefulWidget {
  const _ApiKeySection();

  @override
  ConsumerState<_ApiKeySection> createState() => _ApiKeySectionState();
}

class _ApiKeySectionState extends ConsumerState<_ApiKeySection> {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _groupHeader('AI Model Keys',
            'Round-robin across healthy keys for cost balancing.',
            Icons.psychology_rounded),
        const SizedBox(height: 10),
        ..._aiProviders.map((p) => _ProviderKeyCard(provider: p)),
        const SizedBox(height: 20),
        _groupHeader('Media & Stock APIs',
            'Used for video search, stock footage, and thumbnails.',
            Icons.perm_media_rounded),
        const SizedBox(height: 10),
        ..._mediaProviders.map((p) => _ProviderKeyCard(provider: p)),
        const SizedBox(height: 20),
        _groupHeader('Platform Tokens',
            'GitHub PAT for auto-update from private releases.',
            Icons.token_rounded),
        const SizedBox(height: 10),
        ..._platformProviders.map((p) => _ProviderKeyCard(provider: p)),
      ],
    );
  }

  Widget _groupHeader(String title, String subtitle, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Colors.white.withOpacity(0.4)),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Colors.white.withOpacity(0.6))),
            Text(subtitle,
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withOpacity(0.25))),
          ],
        ),
      ],
    );
  }
}

class _ProviderKeyCard extends ConsumerStatefulWidget {
  final LlmProvider provider;
  const _ProviderKeyCard({required this.provider});

  @override
  ConsumerState<_ProviderKeyCard> createState() => _ProviderKeyCardState();
}

class _ProviderKeyCardState extends ConsumerState<_ProviderKeyCard> {
  bool _expanded = false;
  bool _adding = false;
  final _keyController = TextEditingController();

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  IconData get _icon => switch (widget.provider) {
    LlmProvider.openai => Icons.auto_awesome,
    LlmProvider.claude => Icons.smart_toy,
    LlmProvider.gemini => Icons.diamond,
    LlmProvider.github => Icons.code,
    LlmProvider.youtube => Icons.play_circle_filled,
    LlmProvider.pexels => Icons.camera_alt,
    LlmProvider.pixabay => Icons.image,
  };

  Color get _color => switch (widget.provider) {
    LlmProvider.openai => const Color(0xFF10A37F),
    LlmProvider.claude => const Color(0xFFD97706),
    LlmProvider.gemini => const Color(0xFF4285F4),
    LlmProvider.github => Colors.white70,
    LlmProvider.youtube => const Color(0xFFFF0000),
    LlmProvider.pexels => const Color(0xFF05A081),
    LlmProvider.pixabay => const Color(0xFF48B648),
  };

  String get _label => switch (widget.provider) {
    LlmProvider.openai => 'OpenAI',
    LlmProvider.claude => 'Claude (Anthropic)',
    LlmProvider.gemini => 'Gemini (Google)',
    LlmProvider.github => 'GitHub',
    LlmProvider.youtube => 'YouTube Data API',
    LlmProvider.pexels => 'Pexels',
    LlmProvider.pixabay => 'Pixabay',
  };

  String get _hint => switch (widget.provider) {
    LlmProvider.openai => 'sk-...',
    LlmProvider.claude => 'sk-ant-...',
    LlmProvider.gemini => 'AIza...',
    LlmProvider.github => 'ghp_...',
    LlmProvider.youtube => 'AIza...',
    LlmProvider.pexels => 'Pexels API key...',
    LlmProvider.pixabay => 'Pixabay API key...',
  };

  @override
  Widget build(BuildContext context) {
    final apiService = ref.watch(apiKeyServiceProvider);
    final keys = apiService.getKeysForProvider(widget.provider);
    final healthyCount = keys.where((k) => k.isHealthy).length;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          // Provider header row
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  // Provider icon
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: _color.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(_icon, size: 18, color: _color),
                  ),
                  const SizedBox(width: 12),
                  // Provider name + status
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_label,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        if (keys.isEmpty)
                          Text('No keys configured',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.white.withOpacity(0.25)))
                        else
                          Row(
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: healthyCount == keys.length
                                      ? const Color(0xFF00C853)
                                      : healthyCount > 0
                                          ? Colors.orange
                                          : Colors.redAccent,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '${keys.length} key${keys.length > 1 ? 's' : ''}'
                                ' \u2022 $healthyCount healthy',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.white.withOpacity(0.35)),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  // Add button
                  SizedBox(
                    height: 30,
                    child: TextButton.icon(
                      onPressed: () => setState(() {
                        _expanded = true;
                        _adding = true;
                      }),
                      icon: const Icon(Icons.add, size: 14),
                      label: const Text('Add', style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(
                        foregroundColor: _color,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 20,
                    color: Colors.white24,
                  ),
                ],
              ),
            ),
          ),
          // Expanded: key list + add form
          if (_expanded) ...[
            Divider(height: 1, color: Colors.white.withOpacity(0.06)),
            // Add key form
            if (_adding)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 36,
                        child: TextField(
                          controller: _keyController,
                          obscureText: true,
                          autofocus: true,
                          style: const TextStyle(
                              fontSize: 13, fontFamily: 'monospace'),
                          decoration: InputDecoration(
                            hintText: _hint,
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                          ),
                          onSubmitted: (_) => _addKey(apiService),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 36,
                      child: FilledButton(
                        onPressed: () => _addKey(apiService),
                        style: FilledButton.styleFrom(
                          backgroundColor: _color,
                          padding:
                              const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        child: const Text('Save',
                            style: TextStyle(fontSize: 12)),
                      ),
                    ),
                    const SizedBox(width: 4),
                    SizedBox(
                      height: 36,
                      child: IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () => setState(() {
                          _adding = false;
                          _keyController.clear();
                        }),
                        style: IconButton.styleFrom(
                          foregroundColor: Colors.white38,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            // Key list
            if (keys.isNotEmpty)
              ...keys.map((entry) => _buildKeyRow(entry, apiService)),
            if (keys.isEmpty && !_adding)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: Text(
                    'No keys yet. Click "Add" to get started.',
                    style: TextStyle(
                        fontSize: 12, color: Colors.white.withOpacity(0.2)),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildKeyRow(ApiKeyEntry entry, ApiKeyService service) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          // Health indicator
          Tooltip(
            message: entry.isHealthy ? 'Healthy' : 'Unhealthy — may be rate-limited or invalid',
            child: Icon(
              entry.isHealthy
                  ? Icons.check_circle_rounded
                  : Icons.error_rounded,
              color: entry.isHealthy
                  ? const Color(0xFF00C853)
                  : Colors.redAccent,
              size: 14,
            ),
          ),
          const SizedBox(width: 10),
          // Masked key
          Text(
            entry.masked,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.white.withOpacity(0.6),
            ),
          ),
          const Spacer(),
          // Usage count
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.04),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '${entry.usageCount} uses',
              style: TextStyle(
                  fontSize: 10, color: Colors.white.withOpacity(0.25)),
            ),
          ),
          const SizedBox(width: 8),
          // Remove
          SizedBox(
            width: 24,
            height: 24,
            child: IconButton(
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.delete_outline, size: 14),
              color: Colors.white.withOpacity(0.2),
              hoverColor: Colors.redAccent.withOpacity(0.1),
              onPressed: () async {
                await service.removeKey(widget.provider, entry.masked);
                setState(() {});
              },
              tooltip: 'Remove key',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addKey(ApiKeyService service) async {
    final key = _keyController.text.trim();
    if (key.isEmpty) return;
    await service.addKey(widget.provider, key);
    _keyController.clear();
    setState(() => _adding = false);
  }
}

// ═══════════════════════════════════════════════════════════════════
//  CONNECTED ACCOUNTS
// ═══════════════════════════════════════════════════════════════════

class _ConnectedAccountsSection extends ConsumerStatefulWidget {
  const _ConnectedAccountsSection();

  @override
  ConsumerState<_ConnectedAccountsSection> createState() =>
      _ConnectedAccountsSectionState();
}

class _ConnectedAccountsSectionState
    extends ConsumerState<_ConnectedAccountsSection> {
  AccountProvider? _connectingProvider;
  String? _connectError;

  Future<void> _connect(AccountProvider provider) async {
    setState(() {
      _connectingProvider = provider;
      _connectError = null;
    });
    try {
      final accountService = ref.read(accountServiceProvider);
      await accountService.connect(provider);
      if (mounted) setState(() => _connectingProvider = null);
    } catch (e) {
      if (mounted) {
        setState(() {
          _connectingProvider = null;
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
        if (!accountService.hasClientId(AccountProvider.youtube) &&
            !accountService.hasClientId(AccountProvider.twitch)) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.03),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    size: 16, color: Colors.white.withOpacity(0.3)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'OAuth not configured in this build. '
                    'Add GOOGLE_CLIENT_ID and TWITCH_CLIENT_ID to .env.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withOpacity(0.35),
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
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
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 2),
                if (account != null)
                  Text('Connected as ${account.username}',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF00C853)))
                else if (!hasClientId)
                  Text('OAuth not configured',
                      style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withOpacity(0.3)))
                else
                  Text('Not connected',
                      style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withOpacity(0.3))),
              ],
            ),
          ),
          if (account != null)
            TextButton(
              onPressed:
                  _connectingProvider != null ? null : () => _disconnect(provider),
              child: const Text('Disconnect',
                  style: TextStyle(color: Colors.redAccent, fontSize: 12)),
            )
          else
            FilledButton(
              onPressed: (!hasClientId || _connectingProvider != null)
                  ? null
                  : () => _connect(provider),
              style: FilledButton.styleFrom(
                backgroundColor: color.withOpacity(0.8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              child: _connectingProvider == provider
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Connect', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  BROWSER COOKIES — yt-dlp --cookies-from-browser
// ═══════════════════════════════════════════════════════════════════

const _supportedBrowsers = [
  ('', 'Disabled'),
  ('chrome', 'Chrome'),
  ('firefox', 'Firefox'),
  ('edge', 'Edge'),
  ('brave', 'Brave'),
  ('opera', 'Opera'),
  ('chromium', 'Chromium'),
  ('vivaldi', 'Vivaldi'),
  ('safari', 'Safari'),
];

class _BrowserCookieSection extends ConsumerStatefulWidget {
  const _BrowserCookieSection();

  @override
  ConsumerState<_BrowserCookieSection> createState() =>
      _BrowserCookieSectionState();
}

class _BrowserCookieSectionState
    extends ConsumerState<_BrowserCookieSection> {
  static const _storageKey = 'clipmaster_cookie_browser';
  final _storage = const FlutterSecureStorage();
  String _selected = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetchCurrent();
  }

  Future<void> _fetchCurrent() async {
    // Load persisted value from secure storage first.
    try {
      final saved = await _storage.read(key: _storageKey);
      if (saved != null && mounted) {
        setState(() => _selected = saved);
      }
    } catch (_) {}

    // Then sync from sidecar if connected.
    try {
      final ipc = ref.read(ipcClientProvider);
      if (!ipc.isConnected) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final resp = await ipc.send(
        IpcMessage(
          type: MessageType.getCookieBrowser,
          payload: {},
        ),
        timeout: const Duration(seconds: 5),
      );
      if (mounted) {
        setState(() {
          _selected = (resp.payload['browser'] as String?) ?? '';
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setBrowser(String browser) async {
    setState(() => _selected = browser);
    // Persist to secure storage so it survives restarts.
    try {
      await _storage.write(key: _storageKey, value: browser);
    } catch (_) {}
    // Send to sidecar.
    try {
      final ipc = ref.read(ipcClientProvider);
      if (!ipc.isConnected) return;
      await ipc.send(
        IpcMessage(
          type: MessageType.setCookieBrowser,
          payload: {'browser': browser.isEmpty ? null : browser},
        ),
        timeout: const Duration(seconds: 5),
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsCard(
      icon: Icons.cookie_rounded,
      title: 'Browser Cookies',
      children: [
        Text(
          'Share browser cookies with yt-dlp to bypass YouTube '
          'sign-in prompts. Select the browser where you are '
          'logged into YouTube.',
          style: TextStyle(
            fontSize: 12,
            color: Colors.white.withOpacity(0.35),
            height: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        if (_loading)
          const SizedBox(
            height: 36,
            child: Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.04),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
            ),
            child: DropdownButton<String>(
              value: _selected,
              isExpanded: true,
              dropdownColor: const Color(0xFF1E1E2E),
              underline: const SizedBox.shrink(),
              style: const TextStyle(fontSize: 13),
              items: _supportedBrowsers
                  .map((b) => DropdownMenuItem(
                        value: b.$1,
                        child: Text(b.$2),
                      ))
                  .toList(),
              onChanged: (val) {
                if (val != null) _setBrowser(val);
              },
            ),
          ),
        if (_selected.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.check_circle_rounded,
                  color: Color(0xFF00C853), size: 14),
              const SizedBox(width: 6),
              Text(
                'Using cookies from ${_selected[0].toUpperCase()}${_selected.substring(1)}',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withOpacity(0.4),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  UPDATE CHECKER
// ═══════════════════════════════════════════════════════════════════

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
            Text('Installed',
                style: TextStyle(
                    color: Colors.white.withOpacity(0.4), fontSize: 12)),
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
        const SizedBox(height: 12),
        updateState.when(
          data: (update) {
            if (update == null) {
              return Row(
                children: [
                  const Icon(Icons.check_circle_rounded,
                      color: Color(0xFF00C853), size: 16),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Up to date',
                        style: TextStyle(fontSize: 12)),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        ref.read(updateCheckProvider.notifier).check(),
                    icon: const Icon(Icons.refresh, size: 14),
                    label: const Text('Check', style: TextStyle(fontSize: 11)),
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
                        color: Color(0xFF6C5CE7), size: 16),
                    const SizedBox(width: 8),
                    Text('v${update.version} available',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 12)),
                    const Spacer(),
                    if (update.hasInstaller)
                      FilledButton.icon(
                        onPressed: () => _startUpdate(context, ref, update),
                        icon: const Icon(Icons.download, size: 14),
                        label: const Text('Update',
                            style: TextStyle(fontSize: 11)),
                      )
                    else
                      OutlinedButton.icon(
                        onPressed: () => _openUrl(update.htmlUrl),
                        icon: const Icon(Icons.open_in_new, size: 14),
                        label: const Text('View',
                            style: TextStyle(fontSize: 11)),
                      ),
                  ],
                ),
                if (update.releaseNotes.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.03),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      update.releaseNotes,
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.white.withOpacity(0.4),
                          height: 1.5),
                      maxLines: 4,
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
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white.withOpacity(0.3),
                  )),
              const SizedBox(width: 10),
              Text('Checking...',
                  style: TextStyle(
                      fontSize: 12, color: Colors.white.withOpacity(0.4))),
            ],
          ),
          error: (e, _) => Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  color: Colors.orange, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Check failed',
                    style: const TextStyle(fontSize: 11, color: Colors.orange)),
              ),
              TextButton.icon(
                onPressed: () =>
                    ref.read(updateCheckProvider.notifier).check(),
                icon: const Icon(Icons.refresh, size: 14),
                label: const Text('Retry', style: TextStyle(fontSize: 11)),
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
      Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
    } else if (Platform.isMacOS) {
      Process.run('open', [url]);
    } else {
      Process.run('xdg-open', [url]);
    }
  }
}

// ═══════════════════════════════════════════════════════════════════
//  STORAGE
// ═══════════════════════════════════════════════════════════════════

class _StorageSection extends StatelessWidget {
  const _StorageSection();

  @override
  Widget build(BuildContext context) {
    return _SettingsCard(
      icon: Icons.folder_rounded,
      title: 'Storage',
      children: [
        _FolderRow(
          label: 'App Data',
          getPath: () async =>
              (await getApplicationSupportDirectory()).path,
        ),
        const SizedBox(height: 6),
        _FolderRow(
          label: 'Downloads & Exports',
          getPath: () async {
            final dir = await getApplicationDocumentsDirectory();
            final clipmasterDir =
                Directory('${dir.path}${Platform.pathSeparator}ClipMasterPro');
            if (!clipmasterDir.existsSync()) {
              await clipmasterDir.create(recursive: true);
            }
            return clipmasterDir.path;
          },
        ),
        const SizedBox(height: 6),
        _FolderRow(
          label: 'Temp / Cache',
          getPath: () async =>
              (await getTemporaryDirectory()).path,
        ),
      ],
    );
  }
}

class _FolderRow extends StatefulWidget {
  final String label;
  final Future<String> Function() getPath;

  const _FolderRow({required this.label, required this.getPath});

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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.label,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 12)),
                if (_path != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    _path!,
                    style: TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        color: Colors.white.withOpacity(0.2)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            onPressed: _path != null ? _openFolder : null,
            icon: const Icon(Icons.folder_open, size: 16),
            tooltip: 'Open in explorer',
            style: IconButton.styleFrom(
              foregroundColor: const Color(0xFF6C5CE7),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  SIDECAR STATUS
// ═══════════════════════════════════════════════════════════════════

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
                color: connected ? const Color(0xFF00C853) : Colors.redAccent,
              ),
            ),
          ],
        ),
        if (!connected) ...[
          const SizedBox(height: 10),
          Text(
            'Run setup.bat (Windows) or setup.sh (Linux/Mac), '
            'then restart. Check the Dev Console for details.',
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withOpacity(0.35),
              height: 1.5,
            ),
          ),
        ],
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  ABOUT
// ═══════════════════════════════════════════════════════════════════

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    return _SettingsCard(
      icon: Icons.info_outline_rounded,
      title: 'About',
      children: [
        Row(
          children: [
            Text('ClipMaster Pro',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withOpacity(0.6))),
            const Spacer(),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.06),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'v${AutoUpdater.getInstalledVersion()}',
                style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Colors.white.withOpacity(0.35)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text('AI-powered short-form video creation tool.',
            style: TextStyle(
                fontSize: 12, color: Colors.white.withOpacity(0.25))),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  SHARED CARD
// ═══════════════════════════════════════════════════════════════════

class _SettingsCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> children;

  const _SettingsCard({
    required this.icon,
    required this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: const Color(0xFF6C5CE7)),
                const SizedBox(width: 8),
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14)),
              ],
            ),
            Divider(height: 20, color: Colors.white.withOpacity(0.06)),
            ...children,
          ],
        ),
      ),
    );
  }
}
