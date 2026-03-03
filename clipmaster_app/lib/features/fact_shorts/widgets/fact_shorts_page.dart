import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/ipc/ipc_client.dart';
import '../../../core/ipc/ipc_message.dart';
import '../../../core/services/api_key_service.dart';

const _categories = ['Space', 'History', 'Science', 'Technology', 'Nature'];

class FactShortsPage extends ConsumerStatefulWidget {
  const FactShortsPage({super.key});

  @override
  ConsumerState<FactShortsPage> createState() => _FactShortsPageState();
}

class _FactShortsPageState extends ConsumerState<FactShortsPage> {
  String _selectedCategory = 'Science';
  int _factCount = 5;
  bool _isGenerating = false;
  String _progressStage = '';
  int _progressPercent = 0;
  List<Map<String, dynamic>> _facts = [];
  int? _selectedFactIndex;
  String? _error;

  Future<void> _generate() async {
    // Find an available API key.
    final apiKeyService = ref.read(apiKeyServiceProvider);
    String? apiKey;
    LlmProvider? provider;

    // Try LLM providers in preference order: openai, claude, gemini.
    // Skip github — it's a PAT for the updater, not an LLM key.
    const llmProviders = [LlmProvider.openai, LlmProvider.claude, LlmProvider.gemini];
    for (final p in llmProviders) {
      final key = apiKeyService.getNextKey(p);
      if (key != null) {
        apiKey = key;
        provider = p;
        break;
      }
    }

    if (apiKey == null || provider == null) {
      setState(() {
        _error = 'No API keys configured. Go to Settings and add one '
            '(OpenAI, Claude, or Gemini).';
      });
      return;
    }

    setState(() {
      _isGenerating = true;
      _error = null;
      _facts = [];
      _selectedFactIndex = null;
      _progressStage = 'Starting';
      _progressPercent = 0;
    });

    try {
      final ipc = ref.read(ipcClientProvider);
      final response = await ipc.send(
        IpcMessage(
          type: MessageType.generateFacts,
          payload: {
            'category': _selectedCategory.toLowerCase(),
            'count': _factCount,
            'provider': provider.name,
            'api_key': apiKey,
          },
        ),
        // LLM calls can take 15-30s depending on provider.
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

      if (response.type == MessageType.error) {
        setState(() {
          _isGenerating = false;
          _error = response.payload['message'] as String? ?? 'Unknown error';
        });
      } else {
        final factList =
            (response.payload['facts'] as List<dynamic>? ?? [])
                .cast<Map<String, dynamic>>();
        setState(() {
          _isGenerating = false;
          _facts = factList;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isGenerating = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _createShort() async {
    if (_selectedFactIndex == null) return;
    final fact = _facts[_selectedFactIndex!];
    final factText = fact['fact'] as String? ?? '';
    final factTitle = fact['title'] as String? ?? 'Untitled Fact';
    final visualKeywords =
        (fact['visual_keywords'] as List<dynamic>?)?.cast<String>() ?? [];
    if (factText.isEmpty) return;

    final apiKeyService = ref.read(apiKeyServiceProvider);
    final openaiKey = apiKeyService.getNextKey(LlmProvider.openai);
    if (openaiKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('OpenAI API key required for video creation. Add one in Settings.'),
        ),
      );
      return;
    }

    // Get a proper output directory under Documents.
    final docsDir = await getApplicationDocumentsDirectory();
    final shortsDir = Directory(
      '${docsDir.path}${Platform.pathSeparator}ClipMaster Pro${Platform.pathSeparator}shorts',
    );
    if (!shortsDir.existsSync()) {
      await shortsDir.create(recursive: true);
    }

    setState(() {
      _isGenerating = true;
      _progressStage = 'Creating short';
      _progressPercent = 0;
    });

    try {
      final ipc = ref.read(ipcClientProvider);

      // Build payload with optional stock footage keys.
      final payload = <String, dynamic>{
        'text': factText,
        'title': factTitle,
        'api_key': openaiKey,
        'voice': 'onyx',
        'output_dir': shortsDir.path,
        'visual_keywords': visualKeywords,
      };

      final pexelsKey = apiKeyService.getNextKey(LlmProvider.pexels);
      final pixabayKey = apiKeyService.getNextKey(LlmProvider.pixabay);
      if (pexelsKey != null) payload['pexels_key'] = pexelsKey;
      if (pixabayKey != null) payload['pixabay_key'] = pixabayKey;

      final response = await ipc.send(
        IpcMessage(
          type: MessageType.createShort,
          payload: payload,
        ),
        timeout: const Duration(minutes: 5),
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _progressStage =
                  progress.payload['stage'] as String? ?? 'Creating short';
              _progressPercent = progress.payload['percent'] as int? ?? 0;
            });
          }
        },
      );

      if (!mounted) return;

      if (response.type == MessageType.error) {
        setState(() {
          _isGenerating = false;
          _error = response.payload['message'] as String? ?? 'Short creation failed';
        });
      } else {
        final outputPath = response.payload['output_path'] as String? ?? '';
        final duration = (response.payload['duration'] as num?)?.toDouble() ?? 0;
        setState(() => _isGenerating = false);

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Short created! ${duration.toStringAsFixed(0)}s video saved.',
            ),
            duration: const Duration(seconds: 6),
            action: outputPath.isNotEmpty
                ? SnackBarAction(
                    label: 'Open Folder',
                    onPressed: () {
                      final dir = outputPath.substring(
                        0,
                        outputPath.lastIndexOf(Platform.pathSeparator),
                      );
                      if (Platform.isWindows) {
                        Process.run('explorer.exe', [dir]);
                      } else if (Platform.isMacOS) {
                        Process.run('open', [dir]);
                      } else {
                        Process.run('xdg-open', [dir]);
                      }
                    },
                  )
                : null,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isGenerating = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, size: 28, color: Color(0xFF6C5CE7)),
              const SizedBox(width: 12),
              Text('Fact Shorts', style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
              )),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Generate AI-powered facts and turn them into short-form videos.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white.withOpacity(0.4),
            ),
          ),
          const SizedBox(height: 20),
          // Category chips
          Wrap(
            spacing: 8,
            children: _categories.map((cat) {
              return ChoiceChip(
                label: Text(cat),
                selected: _selectedCategory == cat,
                onSelected: (_) {
                  setState(() {
                    _selectedCategory = cat;
                  });
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          // Controls row
          Row(
            children: [
              const Text('Facts:', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: _factCount,
                items: [1, 3, 5, 8, 10]
                    .map((n) =>
                        DropdownMenuItem(value: n, child: Text('$n')))
                    .toList(),
                onChanged: (v) => setState(() => _factCount = v!),
              ),
              const SizedBox(width: 16),
              FilledButton.icon(
                onPressed: _isGenerating ? null : _generate,
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('Generate Facts'),
              ),
              if (_facts.isNotEmpty) ...[
                const SizedBox(width: 16),
                TextButton.icon(
                  onPressed: () => setState(() {
                    _facts = [];
                    _selectedFactIndex = null;
                    _error = null;
                  }),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('New Facts'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          Expanded(child: _buildContent(theme)),
        ],
      ),
    );
  }

  Widget _buildContent(ThemeData theme) {
    if (_isGenerating) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('$_progressStage... $_progressPercent%'),
            const SizedBox(height: 8),
            SizedBox(
              width: 200,
              child: LinearProgressIndicator(
                value: _progressPercent / 100,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Asking AI for $_factCount $_selectedCategory facts...',
              style: const TextStyle(fontSize: 12, color: Colors.white38),
            ),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
            const SizedBox(height: 16),
            SizedBox(
              width: 400,
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => setState(() => _error = null),
              icon: const Icon(Icons.refresh),
              label: const Text('Try Again'),
            ),
          ],
        ),
      );
    }

    if (_facts.isNotEmpty) {
      return _buildFactsList(theme);
    }

    // Empty state
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: 64,
              color: Colors.white.withOpacity(0.15)),
          const SizedBox(height: 16),
          const Text(
            'Select a category and click "Generate Facts"\n'
            'to get AI-generated facts for your next short.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 15),
          ),
          const SizedBox(height: 12),
          Text(
            'Requires an API key (OpenAI, Claude, or Gemini)\nconfigured in Settings.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withOpacity(0.2), fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildFactsList(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '${_facts.length} $_selectedCategory Facts',
              style: theme.textTheme.titleMedium,
            ),
            const Spacer(),
            if (_selectedFactIndex != null)
              FilledButton.icon(
                onPressed: _isGenerating ? null : _createShort,
                icon: const Icon(Icons.movie_creation, size: 18),
                label: const Text('Create Short'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView.builder(
            itemCount: _facts.length,
            itemBuilder: (context, index) {
              return _FactCard(
                fact: _facts[index],
                index: index,
                isSelected: _selectedFactIndex == index,
                onTap: () {
                  setState(() {
                    _selectedFactIndex =
                        _selectedFactIndex == index ? null : index;
                  });
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FactCard extends StatelessWidget {
  final Map<String, dynamic> fact;
  final int index;
  final bool isSelected;
  final VoidCallback onTap;

  const _FactCard({
    required this.fact,
    required this.index,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final title = fact['title'] as String? ?? 'Untitled';
    final body = fact['fact'] as String? ?? '';
    final keywords = (fact['visual_keywords'] as List<dynamic>?)
            ?.cast<String>() ??
        [];

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isSelected
            ? const BorderSide(color: Color(0xFF6C5CE7), width: 2)
            : BorderSide.none,
      ),
      color: isSelected
          ? const Color(0xFF6C5CE7).withOpacity(0.08)
          : null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Number badge
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF6C5CE7)
                          : Colors.white10,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${index + 1}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: isSelected ? Colors.white : Colors.white54,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  // Copy button
                  IconButton(
                    icon: const Icon(Icons.content_copy, size: 18),
                    tooltip: 'Copy narration script',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: body));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Script copied to clipboard'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                body,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: Colors.white70,
                ),
              ),
              if (keywords.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: keywords.map((kw) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6C5CE7).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        kw,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF6C5CE7),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
