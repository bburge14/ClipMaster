import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/api_key_service.dart';

/// Settings page for managing BYOK API keys.
///
/// Users can add/remove keys for Gemini, Claude, and OpenAI.
/// Keys are stored in Windows Credential Manager via flutter_secure_storage.
/// The round-robin status and health of each key is displayed.
class ApiKeySettings extends ConsumerStatefulWidget {
  const ApiKeySettings({super.key});

  @override
  ConsumerState<ApiKeySettings> createState() => _ApiKeySettingsState();
}

class _ApiKeySettingsState extends ConsumerState<ApiKeySettings> {
  final _keyController = TextEditingController();
  LlmProvider _selectedProvider = LlmProvider.openai;

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final apiKeyService = ref.watch(apiKeyServiceProvider);
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('API Key Management', style: theme.textTheme.headlineMedium),
          const SizedBox(height: 8),
          Text(
            'Add your own API keys. Keys are encrypted and stored in '
            'Windows Credential Manager. ClipMaster uses round-robin '
            'load balancing across all healthy keys per provider.',
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white54),
          ),
          const SizedBox(height: 24),

          // Add key form
          Row(
            children: [
              DropdownButton<LlmProvider>(
                value: _selectedProvider,
                items: LlmProvider.values.map((p) {
                  return DropdownMenuItem(
                    value: p,
                    child: Text(p.name.toUpperCase()),
                  );
                }).toList(),
                onChanged: (p) => setState(() => _selectedProvider = p!),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _keyController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    hintText: 'Paste API key...',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: () async {
                  final key = _keyController.text.trim();
                  if (key.isEmpty) return;
                  await apiKeyService.addKey(_selectedProvider, key);
                  _keyController.clear();
                  setState(() {});
                },
                icon: const Icon(Icons.add),
                label: const Text('Add Key'),
              ),
            ],
          ),
          const SizedBox(height: 32),

          // Key list per provider
          Expanded(
            child: ListView(
              children: LlmProvider.values.map((provider) {
                final keys = apiKeyService.getKeysForProvider(provider);
                return _buildProviderSection(provider, keys, apiKeyService);
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProviderSection(
    LlmProvider provider,
    List<ApiKeyEntry> keys,
    ApiKeyService service,
  ) {
    if (keys.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            provider.name.toUpperCase(),
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: Colors.white70,
            ),
          ),
        ),
        ...keys.map((entry) => Card(
              child: ListTile(
                leading: Icon(
                  entry.isHealthy ? Icons.check_circle : Icons.error,
                  color: entry.isHealthy ? Colors.green : Colors.red,
                ),
                title: Text(entry.masked,
                    style: const TextStyle(fontFamily: 'monospace')),
                subtitle: Text(
                  'Used ${entry.usageCount}x • '
                  'Last: ${entry.lastUsed?.toIso8601String().substring(0, 16) ?? "never"}',
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await service.removeKey(provider, entry.masked);
                    setState(() {});
                  },
                ),
              ),
            )),
        const SizedBox(height: 16),
      ],
    );
  }
}
