import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ipc/ipc_client.dart';
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
          Text('Settings', style: theme.textTheme.headlineMedium),
          const SizedBox(height: 24),
          const _UpdateSection(),
          const SizedBox(height: 24),
          const _SidecarStatusSection(),
          const SizedBox(height: 24),
          const _ApiKeySummarySection(),
          const SizedBox(height: 24),
          _AboutSection(),
        ],
      ),
    );
  }
}

// ───────────────────── Update Checker ─────────────────────

class _UpdateSection extends ConsumerWidget {
  const _UpdateSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updateState = ref.watch(updateCheckProvider);
    final currentVersion = AutoUpdater.getInstalledVersion();

    return _SettingsCard(
      icon: Icons.system_update,
      title: 'Updates',
      children: [
        Row(
          children: [
            Text('Current version: ',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
            Text('v$currentVersion',
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 12),
        updateState.when(
          data: (update) {
            if (update == null) {
              return Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 18),
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
                    const Icon(Icons.new_releases,
                        color: Color(0xFF6C5CE7), size: 18),
                    const SizedBox(width: 8),
                    Text(
                      'Update available: v${update.version}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13),
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
                        label: const Text('View on GitHub'),
                      ),
                  ],
                ),
                if (update.releaseNotes.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      update.releaseNotes,
                      style:
                          const TextStyle(fontSize: 12, color: Colors.white54),
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            );
          },
          loading: () => const Row(
            children: [
              SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 8),
              Text('Checking for updates...',
                  style: TextStyle(fontSize: 13, color: Colors.white54)),
            ],
          ),
          error: (e, _) => Row(
            children: [
              const Icon(Icons.warning_amber, color: Colors.orange, size: 18),
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
        const SizedBox(height: 8),
        const Text(
          'Updates are checked automatically every 30 minutes.\n'
          'For private repos, add a GitHub Personal Access Token in API Keys.',
          style: TextStyle(fontSize: 11, color: Colors.white24),
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

// ───────────────────── Sidecar Status ─────────────────────

class _SidecarStatusSection extends ConsumerWidget {
  const _SidecarStatusSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ipc = ref.watch(ipcClientProvider);
    final connected = ipc.isConnected;

    return _SettingsCard(
      icon: Icons.dns,
      title: 'Python Sidecar',
      children: [
        Row(
          children: [
            Icon(
              connected ? Icons.check_circle : Icons.error,
              color: connected ? Colors.green : Colors.redAccent,
              size: 18,
            ),
            const SizedBox(width: 8),
            Text(
              connected ? 'Connected' : 'Not connected',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: connected ? Colors.green : Colors.redAccent,
              ),
            ),
          ],
        ),
        if (!connected) ...[
          const SizedBox(height: 8),
          const Text(
            'The Python sidecar handles AI features (Fact Shorts, Viral Scout). '
            'If it failed to start, check:\n'
            '  1. Run setup.bat (Windows) or setup.sh (Mac/Linux) first\n'
            '  2. Python 3.10+ must be installed\n'
            '  3. Check the Dev Console for error details',
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
        ],
      ],
    );
  }
}

// ───────────────────── API Key Summary ─────────────────────

class _ApiKeySummarySection extends ConsumerWidget {
  const _ApiKeySummarySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final apiService = ref.watch(apiKeyServiceProvider);

    final counts = <String, int>{};
    for (final p in LlmProvider.values) {
      final keys = apiService.getKeysForProvider(p);
      if (keys.isNotEmpty) counts[p.name] = keys.length;
    }

    return _SettingsCard(
      icon: Icons.key,
      title: 'API Keys',
      children: [
        if (counts.isEmpty)
          const Text(
            'No API keys configured. Go to the API Keys tab to add one.',
            style: TextStyle(fontSize: 13, color: Colors.white54),
          )
        else
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: counts.entries.map((e) {
              return Chip(
                avatar: const Icon(Icons.vpn_key, size: 14),
                label: Text('${e.key.toUpperCase()}: ${e.value} key(s)',
                    style: const TextStyle(fontSize: 12)),
              );
            }).toList(),
          ),
      ],
    );
  }
}

// ───────────────────── About ─────────────────────

class _AboutSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return _SettingsCard(
      icon: Icons.info_outline,
      title: 'About',
      children: [
        Text(
          'ClipMaster Pro — AI-powered short-form video creation tool.',
          style: TextStyle(fontSize: 13, color: Colors.white54),
        ),
        const SizedBox(height: 4),
        Text(
          'Version: v${AutoUpdater.getInstalledVersion()}',
          style: const TextStyle(
              fontSize: 12, fontFamily: 'monospace', color: Colors.white38),
        ),
      ],
    );
  }
}

// ───────────────────── Shared Card ─────────────────────

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
                      fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
            const Divider(height: 24),
            ...children,
          ],
        ),
      ),
    );
  }
}
