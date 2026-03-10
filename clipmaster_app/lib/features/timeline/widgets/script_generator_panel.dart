import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ipc/ipc_client.dart';
import '../../../core/ipc/ipc_message.dart';
import '../../../core/services/api_key_service.dart';
import '../../../core/services/project_state.dart';

const _categories = ['Space', 'History', 'Science', 'Technology', 'Nature'];

/// A generated fact/script entry.
class GeneratedFact {
  final String title;
  final String script;
  final List<String> visualKeywords;
  final LlmProvider provider;

  const GeneratedFact({
    required this.title,
    required this.script,
    required this.visualKeywords,
    required this.provider,
  });
}

/// Callback when a fact is selected — feeds into the unified editor.
typedef OnFactSelected = void Function(GeneratedFact fact);

/// Script Generator snap-in panel for the unified editor.
///
/// Generates AI facts/scripts from multiple LLM providers and lets the user
/// select one. The selected fact populates the editor's project state
/// (script, title, visual keywords) so the timeline, preview, and other
/// panels all update automatically.
class ScriptGeneratorPanel extends ConsumerStatefulWidget {
  final OnFactSelected onFactSelected;
  final VoidCallback onClose;

  const ScriptGeneratorPanel({
    super.key,
    required this.onFactSelected,
    required this.onClose,
  });

  @override
  ConsumerState<ScriptGeneratorPanel> createState() =>
      _ScriptGeneratorPanelState();
}

class _ScriptGeneratorPanelState extends ConsumerState<ScriptGeneratorPanel> {
  String _selectedCategory = 'Science';
  int _factCount = 5;
  bool _isGenerating = false;
  String _progressStage = '';
  int _progressPercent = 0;
  String? _error;

  // Multi-model fact generation
  final Map<LlmProvider, List<Map<String, dynamic>>> _modelFacts = {};
  final Map<LlmProvider, bool> _modelLoading = {};
  final Map<LlmProvider, String?> _modelErrors = {};
  final Set<LlmProvider> _enabledProviders = {
    LlmProvider.openai,
    LlmProvider.claude,
    LlmProvider.gemini,
  };

  int? _selectedFactIndex;
  LlmProvider? _selectedFactProvider;

  // Custom prompt
  String _customPrompt = '';
  final _customPromptController = TextEditingController();

  @override
  void dispose() {
    _customPromptController.dispose();
    super.dispose();
  }

  // ── Generation ──

  Future<void> _generate() async {
    final apiKeyService = ref.read(apiKeyServiceProvider);

    final toGenerate = <LlmProvider, String>{};
    for (final p in _enabledProviders) {
      final key = apiKeyService.getNextKey(p);
      if (key != null) toGenerate[p] = key;
    }

    if (toGenerate.isEmpty) {
      setState(() {
        _error = 'No API keys configured for enabled models. '
            'Go to Settings and add one (OpenAI, Claude, or Gemini).';
      });
      return;
    }

    setState(() {
      _isGenerating = true;
      _error = null;
      _modelFacts.clear();
      _modelErrors.clear();
      _selectedFactIndex = null;
      _selectedFactProvider = null;
      _progressStage = 'Starting';
      _progressPercent = 0;
      for (final p in toGenerate.keys) {
        _modelLoading[p] = true;
      }
    });

    final ipc = ref.read(ipcClientProvider);
    final futures = <Future<void>>[];
    for (final entry in toGenerate.entries) {
      futures.add(_generateForProvider(ipc, entry.key, entry.value));
    }
    await Future.wait(futures);

    if (mounted) {
      setState(() => _isGenerating = false);
    }
  }

  Future<void> _generateForProvider(
      IpcClient ipc, LlmProvider provider, String apiKey) async {
    try {
      final response = await ipc.send(
        IpcMessage(
          type: MessageType.generateFacts,
          payload: {
            'category': _selectedCategory.toLowerCase(),
            'count': _factCount,
            'provider': provider.name,
            'api_key': apiKey,
            if (_customPrompt.isNotEmpty) 'custom_prompt': _customPrompt,
          },
        ),
        timeout: const Duration(seconds: 90),
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _progressStage =
                  progress.payload['stage'] as String? ?? 'Generating';
              _progressPercent = progress.payload['percent'] as int? ?? 0;
            });
          }
        },
      );

      if (!mounted) return;

      if (response.type == MessageType.error) {
        setState(() {
          _modelLoading[provider] = false;
          _modelErrors[provider] =
              response.payload['message'] as String? ?? 'Unknown error';
        });
      } else {
        final factList = (response.payload['facts'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();
        setState(() {
          _modelLoading[provider] = false;
          _modelFacts[provider] = factList;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _modelLoading[provider] = false;
          _modelErrors[provider] = e.toString();
        });
      }
    }
  }

  void _selectFact(int index, LlmProvider provider) {
    final facts = _modelFacts[provider];
    if (facts == null || index >= facts.length) return;
    final fact = facts[index];

    setState(() {
      _selectedFactIndex = index;
      _selectedFactProvider = provider;
    });

    widget.onFactSelected(GeneratedFact(
      title: fact['title'] as String? ?? 'Untitled',
      script: fact['fact'] as String? ?? '',
      visualKeywords:
          (fact['visual_keywords'] as List<dynamic>?)?.cast<String>() ?? [],
      provider: provider,
    ));
  }

  // ── Helpers ──

  String _providerLabel(LlmProvider p) {
    switch (p) {
      case LlmProvider.openai:
        return 'GPT-4o';
      case LlmProvider.claude:
        return 'Claude';
      case LlmProvider.gemini:
        return 'Gemini';
      default:
        return p.name;
    }
  }

  Color _providerColor(LlmProvider p) {
    switch (p) {
      case LlmProvider.openai:
        return const Color(0xFF10A37F);
      case LlmProvider.claude:
        return const Color(0xFFD97757);
      case LlmProvider.gemini:
        return const Color(0xFF4285F4);
      default:
        return const Color(0xFF6C5CE7);
    }
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final apiKeyService = ref.read(apiKeyServiceProvider);

    return Container(
      color: const Color(0xFF1A1A2A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(12),
            child: const SizedBox.shrink(),
          ),
          // Controls
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: _categories.map((cat) {
                return ChoiceChip(
                  label: Text(cat, style: const TextStyle(fontSize: 11)),
                  selected: _selectedCategory == cat,
                  onSelected: (_) =>
                      setState(() => _selectedCategory = cat),
                  visualDensity: VisualDensity.compact,
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 8),
          // Custom prompt
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: _customPromptController,
              maxLines: 2,
              style: const TextStyle(fontSize: 11),
              decoration: InputDecoration(
                hintText: 'Custom prompt (optional)...',
                hintStyle: TextStyle(
                    fontSize: 10, color: Colors.white.withOpacity(0.2)),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide:
                      BorderSide(color: Colors.white.withOpacity(0.1)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide:
                      BorderSide(color: Colors.white.withOpacity(0.08)),
                ),
                suffixIcon: _customPrompt.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 14),
                        onPressed: () => setState(() {
                          _customPrompt = '';
                          _customPromptController.clear();
                        }),
                      )
                    : null,
              ),
              onChanged: (v) => setState(() => _customPrompt = v.trim()),
            ),
          ),
          const SizedBox(height: 8),
          // AI model toggles
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children:
                  [LlmProvider.openai, LlmProvider.claude, LlmProvider.gemini]
                      .map((p) {
                final hasKey = apiKeyService.getNextKey(p) != null;
                final enabled = _enabledProviders.contains(p);
                return FilterChip(
                  label: Text(_providerLabel(p),
                      style: const TextStyle(fontSize: 10)),
                  selected: enabled,
                  onSelected: hasKey
                      ? (v) {
                          setState(() {
                            if (v) {
                              _enabledProviders.add(p);
                            } else if (_enabledProviders.length > 1) {
                              _enabledProviders.remove(p);
                            }
                          });
                        }
                      : null,
                  avatar: hasKey
                      ? null
                      : Icon(Icons.key_off,
                          size: 12, color: Colors.white.withOpacity(0.2)),
                  tooltip: hasKey ? null : 'No API key configured',
                  visualDensity: VisualDensity.compact,
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 8),
          // Generate row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const Text('Facts:', style: TextStyle(fontSize: 11)),
                const SizedBox(width: 4),
                DropdownButton<int>(
                  value: _factCount,
                  isDense: true,
                  items: [1, 3, 5, 8, 10]
                      .map((n) =>
                          DropdownMenuItem(value: n, child: Text('$n')))
                      .toList(),
                  onChanged: (v) => setState(() => _factCount = v!),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isGenerating ? null : _generate,
                    icon: const Icon(Icons.auto_awesome, size: 14),
                    label: const Text('Generate',
                        style: TextStyle(fontSize: 11)),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_isGenerating)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: LinearProgressIndicator(
                value: _progressPercent / 100.0,
                minHeight: 3,
                backgroundColor: Colors.white10,
                valueColor: const AlwaysStoppedAnimation(Color(0xFF6C5CE7)),
              ),
            ),
          const SizedBox(height: 8),
          Divider(height: 1, color: Colors.white.withOpacity(0.06)),
          // Fact list
          Expanded(child: _buildFactList()),
        ],
      ),
    );
  }

  Widget _buildFactList() {
    final hasAnyFacts = _modelFacts.values.any((f) => f.isNotEmpty);
    final anyLoading = _modelLoading.values.any((v) => v);

    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 32, color: Colors.redAccent),
            const SizedBox(height: 8),
            Text(_error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() => _error = null),
              child: const Text('Dismiss', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );
    }

    if (!hasAnyFacts && !anyLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome,
                size: 40, color: Colors.white.withOpacity(0.08)),
            const SizedBox(height: 8),
            Text(
              'Generate facts\nto get started.',
              textAlign: TextAlign.center,
              style:
                  TextStyle(color: Colors.white.withOpacity(0.2), fontSize: 12),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        for (final provider in _enabledProviders) ...[
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 6, left: 4),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _providerColor(provider),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _providerLabel(provider),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: _providerColor(provider),
                  ),
                ),
                const Spacer(),
                if (_modelLoading[provider] == true)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: _providerColor(provider).withOpacity(0.5),
                    ),
                  ),
                if (_modelErrors[provider] != null)
                  Tooltip(
                    message: _modelErrors[provider]!,
                    child: Icon(Icons.warning_amber,
                        size: 14, color: Colors.amber.withOpacity(0.6)),
                  ),
              ],
            ),
          ),
          if (_modelFacts[provider] != null)
            for (var i = 0; i < _modelFacts[provider]!.length; i++)
              _buildFactCard(_modelFacts[provider]![i], i, provider),
          if (_modelFacts[provider] == null &&
              _modelLoading[provider] != true)
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 8),
              child: Text('No results',
                  style: TextStyle(
                      fontSize: 10, color: Colors.white.withOpacity(0.2))),
            ),
        ],
      ],
    );
  }

  Widget _buildFactCard(
      Map<String, dynamic> fact, int index, LlmProvider provider) {
    final title = fact['title'] as String? ?? 'Untitled';
    final body = fact['fact'] as String? ?? '';
    final isSelected =
        _selectedFactIndex == index && _selectedFactProvider == provider;

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: isSelected
            ? BorderSide(color: _providerColor(provider), width: 2)
            : BorderSide.none,
      ),
      color: isSelected ? _providerColor(provider).withOpacity(0.08) : null,
      child: InkWell(
        onTap: () => _selectFact(index, provider),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: isSelected
                      ? _providerColor(provider)
                      : Colors.white10,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                    color: isSelected ? Colors.white : Colors.white54,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Text(body,
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.white.withOpacity(0.4)),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              // Copy button
              IconButton(
                icon: const Icon(Icons.copy, size: 14),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: '$title\n\n$body'));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Copied to clipboard'),
                        duration: Duration(seconds: 1)),
                  );
                },
                style: IconButton.styleFrom(
                  foregroundColor: Colors.white24,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(28, 28),
                ),
                tooltip: 'Copy',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
