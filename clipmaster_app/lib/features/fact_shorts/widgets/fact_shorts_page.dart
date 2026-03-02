import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ipc/ipc_client.dart';
import '../../../core/ipc/ipc_message.dart';

/// Sample scripts by category so users can try the feature immediately.
const _sampleScripts = {
  'Space':
      'Deep in the cosmos a supernova explodes sending shockwaves across the galaxy. '
          'The resulting nebula glows with brilliant colors for thousands of years. '
          'Stars are born from these clouds of cosmic dust and gas. '
          'Our own Sun formed this way nearly five billion years ago. '
          'One day it too will expand into a red giant engulfing Mercury and Venus. '
          'But that is billions of years from now so there is no need to worry just yet.',
  'History':
      'In 1969 astronauts walked on the Moon for the very first time. '
          'Neil Armstrong descended the ladder of the lunar module Eagle. '
          'He planted the American flag in the gray lunar soil. '
          'Millions of people around the world watched on their television sets. '
          'It was one of the most watched broadcasts in human history. '
          'The Apollo program would send twelve people to the Moon before it ended.',
  'Science':
      'The human brain contains roughly eighty-six billion neurons. '
          'Each neuron can form thousands of connections with other neurons. '
          'This vast network allows us to think dream and remember. '
          'Scientists are only beginning to understand how consciousness arises. '
          'Advanced brain imaging techniques reveal patterns of activity. '
          'One day we may be able to decode thoughts directly from neural signals.',
  'Technology':
      'Artificial intelligence is transforming every industry on the planet. '
          'Self-driving cars navigate city streets using cameras and lidar sensors. '
          'Language models can write code translate languages and summarize documents. '
          'Robots in factories assemble products with superhuman precision. '
          'Quantum computers promise to solve problems that are impossible today. '
          'The next decade will bring changes we can barely imagine.',
  'Nature':
      'The Amazon rainforest produces twenty percent of the world oxygen supply. '
          'It is home to more than ten percent of all species on Earth. '
          'Colorful macaws fly above the canopy while jaguars prowl below. '
          'Rivers wind through the dense vegetation for thousands of miles. '
          'Indigenous communities have lived here in harmony for millennia. '
          'Deforestation threatens this incredible ecosystem every single day.',
};

class FactShortsPage extends ConsumerStatefulWidget {
  const FactShortsPage({super.key});

  @override
  ConsumerState<FactShortsPage> createState() => _FactShortsPageState();
}

class _FactShortsPageState extends ConsumerState<FactShortsPage> {
  final _scriptController = TextEditingController();
  String _selectedCategory = 'Space';
  int _blockDuration = 5;
  bool _isAnalyzing = false;
  String _progressStage = '';
  int _progressPercent = 0;
  Map<String, String> _results = {};
  String? _error;

  @override
  void dispose() {
    _scriptController.dispose();
    super.dispose();
  }

  Future<void> _analyze() async {
    final text = _scriptController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _isAnalyzing = true;
      _error = null;
      _results = {};
      _progressStage = 'Starting';
      _progressPercent = 0;
    });

    try {
      final ipc = ref.read(ipcClientProvider);
      final response = await ipc.send(
        IpcMessage(
          type: MessageType.analyzeScript,
          payload: {
            'script': text,
            'block_duration_seconds': _blockDuration,
          },
        ),
        onProgress: (progress) {
          setState(() {
            _progressStage =
                progress.payload['stage'] as String? ?? 'Analyzing';
            _progressPercent = progress.payload['percent'] as int? ?? 0;
          });
        },
      );

      if (response.type == MessageType.error) {
        setState(() {
          _isAnalyzing = false;
          _error = response.payload['message'] as String? ?? 'Unknown error';
        });
      } else {
        final rawMap =
            response.payload['visual_map'] as Map<String, dynamic>? ?? {};
        setState(() {
          _isAnalyzing = false;
          _results = rawMap.map((k, v) => MapEntry(k, v.toString()));
        });
      }
    } catch (e) {
      setState(() {
        _isAnalyzing = false;
        _error = e.toString();
      });
    }
  }

  void _clear() {
    setState(() {
      _results = {};
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Fact-Shorts Generator', style: theme.textTheme.headlineMedium),
          const SizedBox(height: 8),
          Text(
            'Paste a narration script to generate timestamped visual keywords '
            'for B-roll auto-assembly. Pick a category for a sample script.',
            style:
                theme.textTheme.bodyMedium?.copyWith(color: Colors.white54),
          ),
          const SizedBox(height: 20),
          // Category chips
          Wrap(
            spacing: 8,
            children: _sampleScripts.keys.map((cat) {
              return ChoiceChip(
                label: Text(cat),
                selected: _selectedCategory == cat,
                onSelected: (_) {
                  setState(() {
                    _selectedCategory = cat;
                    _scriptController.text = _sampleScripts[cat]!;
                    _results = {};
                    _error = null;
                  });
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          // Controls row
          Row(
            children: [
              const Text('Block duration:', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: _blockDuration,
                items: [3, 5, 10]
                    .map((d) =>
                        DropdownMenuItem(value: d, child: Text('${d}s')))
                    .toList(),
                onChanged: (v) => setState(() => _blockDuration = v!),
              ),
              const SizedBox(width: 16),
              if (_results.isNotEmpty)
                FilledButton.icon(
                  onPressed: _clear,
                  icon: const Icon(Icons.clear, size: 18),
                  label: const Text('Clear'),
                )
              else
                FilledButton.icon(
                  onPressed: _isAnalyzing ? null : _analyze,
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  label: const Text('Analyze Script'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          // Main content
          Expanded(child: _buildContent(theme)),
        ],
      ),
    );
  }

  Widget _buildContent(ThemeData theme) {
    if (_isAnalyzing) {
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
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _clear,
              icon: const Icon(Icons.refresh),
              label: const Text('Try Again'),
            ),
          ],
        ),
      );
    }

    if (_results.isNotEmpty) {
      return _buildResults(theme);
    }

    // Script input
    return TextField(
      controller: _scriptController,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      style: const TextStyle(fontSize: 14, height: 1.6),
      decoration: InputDecoration(
        hintText: 'Paste your narration script here...\n\n'
            'Or select a category above to load a sample.',
        hintStyle: TextStyle(color: Colors.white.withOpacity(0.25)),
        border: const OutlineInputBorder(),
        alignLabelWithHint: true,
      ),
    );
  }

  Widget _buildResults(ThemeData theme) {
    final entries = _results.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    final wordCount = _scriptController.text.trim().split(RegExp(r'\s+')).length;
    final estimatedSeconds = (wordCount / 2.5).round();
    final mins = estimatedSeconds ~/ 60;
    final secs = estimatedSeconds % 60;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Visual Map',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(width: 12),
            Text(
              '${entries.length} blocks  ~${mins}m ${secs}s  '
              '$wordCount words',
              style: const TextStyle(fontSize: 12, color: Colors.white38),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              return Card(
                child: ListTile(
                  leading: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6C5CE7).withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      entry.key,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  title: Text(entry.value),
                  trailing: IconButton(
                    icon: const Icon(Icons.content_copy, size: 18),
                    tooltip: 'Copy keyword',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: entry.value));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Copied: ${entry.value}'),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
