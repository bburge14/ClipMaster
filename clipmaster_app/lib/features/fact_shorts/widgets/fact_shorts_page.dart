import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/ipc/ipc_client.dart';
import '../../../core/ipc/ipc_message.dart';
import '../../../core/services/api_key_service.dart';
import '../../../core/services/project_state.dart';

const _categories = ['Space', 'History', 'Science', 'Technology', 'Nature'];

class FactShortsPage extends ConsumerStatefulWidget {
  const FactShortsPage({super.key});

  @override
  ConsumerState<FactShortsPage> createState() => _FactShortsPageState();
}

class _FactShortsPageState extends ConsumerState<FactShortsPage> {
  // ── Fact generation ──
  String _selectedCategory = 'Science';
  int _factCount = 5;
  bool _isGenerating = false;
  String _progressStage = '';
  int _progressPercent = 0;
  List<Map<String, dynamic>> _facts = [];
  int? _selectedFactIndex;
  String? _error;

  // ── Composer state (active when a fact is selected) ──
  String _composerTitle = '';
  String _composerScript = '';
  List<String> _visualKeywords = [];
  TtsVoice _selectedVoice = TtsVoice.onyx;

  // Text editing
  bool _editingScript = false;
  final _scriptEditController = TextEditingController();

  // Voice preview
  Player? _voicePreviewPlayer;
  VideoController? _voicePreviewController;
  bool _isPreviewingVoice = false;
  String? _previewAudioPath;
  bool _voicePlaying = false;

  // Background footage — multiple backgrounds that cycle
  List<Map<String, dynamic>> _bgResults = [];
  bool _isSearchingBg = false;
  List<Map<String, dynamic>> _selectedBackgrounds = []; // ordered list
  int _activeBgIndex = 0; // which background is shown in preview
  Player? _bgPlayer;
  VideoController? _bgController;

  // Timeline scrubber
  double _scrubPosition = 0.0;
  double _estimatedDuration = 30.0;

  // Music (placeholder for future)
  String? _selectedMusicLabel;

  // Rendering
  bool _isRendering = false;

  // Caption style for this composer
  String _fontFamily = 'Inter';
  double _fontSize = 36;
  int _colorHex = 0xFFFFFFFF;
  bool _hasBorder = true;
  double _textPosX = 0.5;
  double _textPosY = 0.75;
  // Text box size as fraction of frame (0.0–1.0)
  double _textBoxW = 0.85;
  double _textBoxH = 0.35;

  @override
  void dispose() {
    _scriptEditController.dispose();
    _voicePreviewPlayer?.dispose();
    _bgPlayer?.dispose();
    super.dispose();
  }

  // ════════════════════════════════════════════════════════════════
  //  FACT GENERATION
  // ════════════════════════════════════════════════════════════════

  Future<void> _generate() async {
    final apiKeyService = ref.read(apiKeyServiceProvider);
    String? apiKey;
    LlmProvider? provider;

    const llmProviders = [
      LlmProvider.openai,
      LlmProvider.claude,
      LlmProvider.gemini
    ];
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
        final factList = (response.payload['facts'] as List<dynamic>? ?? [])
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

  void _selectFact(int index) {
    final fact = _facts[index];
    setState(() {
      _selectedFactIndex = index;
      _composerTitle = fact['title'] as String? ?? 'Untitled';
      _composerScript = fact['fact'] as String? ?? '';
      _visualKeywords =
          (fact['visual_keywords'] as List<dynamic>?)?.cast<String>() ?? [];
      _editingScript = false;
      _scrubPosition = 0;
      _estimatedDuration =
          (_composerScript.split(' ').length / 2.5).clamp(10, 90);

      // Auto-search for background footage
      if (_visualKeywords.isNotEmpty) {
        _searchBackgrounds(_visualKeywords.first);
      }
    });
  }

  // ════════════════════════════════════════════════════════════════
  //  VOICE PREVIEW
  // ════════════════════════════════════════════════════════════════

  Future<void> _previewVoice() async {
    final apiKeyService = ref.read(apiKeyServiceProvider);
    final openaiKey = apiKeyService.getNextKey(LlmProvider.openai);
    if (openaiKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('OpenAI API key required for voice preview.')),
      );
      return;
    }

    // Use the first ~30 words of the script for a quick preview
    final words = _composerScript.split(' ');
    final sampleText = words.take(30).join(' ');
    if (sampleText.isEmpty) return;

    setState(() => _isPreviewingVoice = true);

    try {
      final ipc = ref.read(ipcClientProvider);
      final response = await ipc.send(
        IpcMessage(
          type: MessageType.generateTts,
          payload: {
            'text': sampleText,
            'api_key': openaiKey,
            'voice': _selectedVoice.name,
          },
        ),
        timeout: const Duration(seconds: 30),
      );

      if (!mounted) return;

      if (response.type == MessageType.error) {
        setState(() => _isPreviewingVoice = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(response.payload['message'] as String? ??
                  'Voice preview failed')),
        );
        return;
      }

      final audioPath = response.payload['audio_path'] as String? ?? '';
      if (audioPath.isEmpty) {
        setState(() => _isPreviewingVoice = false);
        return;
      }

      // Play the preview audio
      _voicePreviewPlayer?.dispose();
      _voicePreviewPlayer = Player();
      _voicePreviewPlayer!.open(Media(audioPath));
      _voicePreviewPlayer!.stream.playing.listen((playing) {
        if (mounted) setState(() => _voicePlaying = playing);
      });
      _voicePreviewPlayer!.stream.completed.listen((completed) {
        if (completed && mounted) {
          setState(() {
            _voicePlaying = false;
            _isPreviewingVoice = false;
          });
        }
      });

      setState(() {
        _previewAudioPath = audioPath;
        _isPreviewingVoice = false;
        _voicePlaying = true;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _isPreviewingVoice = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Voice preview failed: $e')),
        );
      }
    }
  }

  // ════════════════════════════════════════════════════════════════
  //  BACKGROUND FOOTAGE SEARCH
  // ════════════════════════════════════════════════════════════════

  Future<void> _searchBackgrounds(String query) async {
    if (query.isEmpty) return;
    final apiKeyService = ref.read(apiKeyServiceProvider);
    final pexelsKey = apiKeyService.getNextKey(LlmProvider.pexels);
    final pixabayKey = apiKeyService.getNextKey(LlmProvider.pixabay);
    if (pexelsKey == null && pixabayKey == null) return;

    setState(() {
      _isSearchingBg = true;
      _bgResults = [];
    });

    try {
      final ipc = ref.read(ipcClientProvider);
      final response = await ipc.send(
        IpcMessage(
          type: MessageType.queryStockFootage,
          payload: {
            'keyword': query,
            if (pexelsKey != null) 'pexels_key': pexelsKey,
            if (pixabayKey != null) 'pixabay_key': pixabayKey,
            'per_source': 4,
          },
        ),
        timeout: const Duration(seconds: 15),
      );

      if (mounted) {
        if (response.type != MessageType.error) {
          final clips = (response.payload['clips'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>();
          setState(() {
            _isSearchingBg = false;
            _bgResults = clips;
          });
        } else {
          setState(() => _isSearchingBg = false);
        }
      }
    } catch (_) {
      if (mounted) setState(() => _isSearchingBg = false);
    }
  }

  void _toggleBackground(Map<String, dynamic> clip) {
    final downloadUrl = clip['download_url'] as String? ?? '';

    setState(() {
      // If already selected, remove it
      final existingIdx = _selectedBackgrounds.indexWhere(
          (b) => b['download_url'] == downloadUrl);
      if (existingIdx >= 0) {
        _selectedBackgrounds.removeAt(existingIdx);
        if (_activeBgIndex >= _selectedBackgrounds.length) {
          _activeBgIndex =
              _selectedBackgrounds.isEmpty ? 0 : _selectedBackgrounds.length - 1;
        }
      } else {
        _selectedBackgrounds.add(clip);
        _activeBgIndex = _selectedBackgrounds.length - 1;
      }
    });

    _loadActiveBgPreview();
  }

  void _loadActiveBgPreview() {
    if (_selectedBackgrounds.isEmpty) {
      _bgPlayer?.dispose();
      _bgPlayer = null;
      _bgController = null;
      setState(() {});
      return;
    }

    final clip = _selectedBackgrounds[_activeBgIndex];
    final previewUrl = clip['preview_url'] as String? ?? '';
    if (previewUrl.isNotEmpty) {
      _bgPlayer?.dispose();
      _bgPlayer = Player();
      _bgController = VideoController(_bgPlayer!);
      _bgPlayer!.open(Media(previewUrl));
      _bgPlayer!.setPlaylistMode(PlaylistMode.loop);
      _bgPlayer!.setVolume(0);
      setState(() {});
    }
  }

  // ════════════════════════════════════════════════════════════════
  //  RENDER / EXPORT
  // ════════════════════════════════════════════════════════════════

  Future<void> _renderShort() async {
    if (_composerScript.isEmpty) return;

    final apiKeyService = ref.read(apiKeyServiceProvider);
    final openaiKey = apiKeyService.getNextKey(LlmProvider.openai);
    if (openaiKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('OpenAI API key required for rendering.')),
      );
      return;
    }

    final docsDir = await getApplicationDocumentsDirectory();
    final shortsDir = Directory(
      '${docsDir.path}${Platform.pathSeparator}ClipMaster Pro${Platform.pathSeparator}shorts',
    );
    if (!shortsDir.existsSync()) {
      await shortsDir.create(recursive: true);
    }

    setState(() {
      _isRendering = true;
      _progressStage = 'Rendering short';
      _progressPercent = 0;
    });

    try {
      final ipc = ref.read(ipcClientProvider);
      // Convert color hex to FFmpeg-friendly format (strip alpha, keep RGB)
      final rgb = _colorHex & 0x00FFFFFF;
      final ffmpegColor = '0x${rgb.toRadixString(16).padLeft(6, '0')}';

      final payload = <String, dynamic>{
        'text': _composerScript,
        'title': _composerTitle,
        'api_key': openaiKey,
        'voice': _selectedVoice.name,
        'output_dir': shortsDir.path,
        'visual_keywords': _visualKeywords,
        // Style params matching the UI preview (WYSIWYG)
        'font_family': _fontFamily,
        'font_size': _fontSize.toInt(),
        'font_color': ffmpegColor,
        'title_pos_y': 0.08,
        'text_pos_y': _textPosY,
        'text_box_w': _textBoxW,
        'text_shadow': _hasBorder,
        // Multiple backgrounds that cycle
        'background_video_urls': _selectedBackgrounds
            .map((b) => b['download_url'] as String? ?? '')
            .where((u) => u.isNotEmpty)
            .toList(),
        // Fallback single URL for backwards compat
        'background_video_url': _selectedBackgrounds.isNotEmpty
            ? (_selectedBackgrounds.first['download_url'] as String? ?? '')
            : '',
      };

      final pexelsKey = apiKeyService.getNextKey(LlmProvider.pexels);
      final pixabayKey = apiKeyService.getNextKey(LlmProvider.pixabay);
      if (pexelsKey != null) payload['pexels_key'] = pexelsKey;
      if (pixabayKey != null) payload['pixabay_key'] = pixabayKey;

      final response = await ipc.send(
        IpcMessage(type: MessageType.createShort, payload: payload),
        timeout: const Duration(minutes: 5),
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _progressStage =
                  progress.payload['stage'] as String? ?? 'Rendering';
              _progressPercent = progress.payload['percent'] as int? ?? 0;
            });
          }
        },
      );

      if (!mounted) return;

      if (response.type == MessageType.error) {
        setState(() => _isRendering = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(response.payload['message'] as String? ??
                  'Render failed')),
        );
      } else {
        final outputPath = response.payload['output_path'] as String? ?? '';
        final duration =
            (response.payload['duration'] as num?)?.toDouble() ?? 0;
        setState(() => _isRendering = false);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Short rendered! ${duration.toStringAsFixed(0)}s video saved.'),
            duration: const Duration(seconds: 6),
            action: outputPath.isNotEmpty
                ? SnackBarAction(
                    label: 'Open Folder',
                    onPressed: () {
                      final dir = outputPath.substring(
                          0, outputPath.lastIndexOf(Platform.pathSeparator));
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
        setState(() => _isRendering = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Render failed: $e')),
        );
      }
    }
  }

  // ════════════════════════════════════════════════════════════════
  //  BUILD UI
  // ════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final hasComposer = _selectedFactIndex != null;

    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              // ── Left panel: fact list ──
              if (hasComposer)
                SizedBox(
                  width: 300,
                  child: _buildFactListPanel(),
                )
              else
                Expanded(child: _buildFactListPanel()),
              // ── Composer (when fact selected) ──
              if (hasComposer) ...[
                Container(width: 1, color: Colors.white.withOpacity(0.06)),
                Expanded(child: _buildComposer()),
              ],
            ],
          ),
        ),
        // ── Bottom: timeline scrubber (only in composer mode) ──
        if (hasComposer) _buildTimelineScrubber(),
      ],
    );
  }

  // ────────────────────────────────────────────────────────────────
  //  LEFT: FACT LIST PANEL
  // ────────────────────────────────────────────────────────────────

  Widget _buildFactListPanel() {
    final isCompact = _selectedFactIndex != null;

    return Container(
      color: const Color(0xFF141420),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome,
                    size: 22, color: Color(0xFF6C5CE7)),
                const SizedBox(width: 8),
                Text(
                  isCompact ? 'Facts' : 'Fact Shorts',
                  style: TextStyle(
                    fontSize: isCompact ? 16 : 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          if (!isCompact) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Generate AI facts and compose them into short-form videos.',
                style: TextStyle(
                    fontSize: 13, color: Colors.white.withOpacity(0.35)),
              ),
            ),
            const SizedBox(height: 12),
          ],
          // Category chips
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: _categories.map((cat) {
                return ChoiceChip(
                  label: Text(cat, style: TextStyle(fontSize: isCompact ? 11 : 13)),
                  selected: _selectedCategory == cat,
                  onSelected: (_) => setState(() => _selectedCategory = cat),
                  visualDensity: isCompact
                      ? VisualDensity.compact
                      : VisualDensity.standard,
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 8),
          // Controls
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                if (!isCompact) ...[
                  const Text('Facts:', style: TextStyle(fontSize: 12)),
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
                ],
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isGenerating || _isRendering ? null : _generate,
                    icon: const Icon(Icons.auto_awesome, size: 16),
                    label: Text(isCompact ? 'Generate' : 'Generate Facts',
                        style: const TextStyle(fontSize: 12)),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Divider(height: 1, color: Colors.white.withOpacity(0.06)),
          // Fact list / loading / error / empty
          Expanded(child: _buildFactListContent(isCompact)),
        ],
      ),
    );
  }

  Widget _buildFactListContent(bool isCompact) {
    if (_isGenerating && _facts.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white.withOpacity(0.4),
              ),
            ),
            const SizedBox(height: 12),
            Text('$_progressStage...',
                style: TextStyle(
                    fontSize: 12, color: Colors.white.withOpacity(0.4))),
          ],
        ),
      );
    }

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

    if (_facts.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome,
                size: 40, color: Colors.white.withOpacity(0.08)),
            const SizedBox(height: 8),
            Text(
              isCompact
                  ? 'Generate facts\nto get started.'
                  : 'Select a category and click\n"Generate Facts" to begin.',
              textAlign: TextAlign.center,
              style:
                  TextStyle(color: Colors.white.withOpacity(0.2), fontSize: 12),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: _facts.length,
      itemBuilder: (context, index) {
        final fact = _facts[index];
        final title = fact['title'] as String? ?? 'Untitled';
        final isSelected = _selectedFactIndex == index;

        return Card(
          margin: const EdgeInsets.only(bottom: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: isSelected
                ? const BorderSide(color: Color(0xFF6C5CE7), width: 2)
                : BorderSide.none,
          ),
          color: isSelected
              ? const Color(0xFF6C5CE7).withOpacity(0.08)
              : null,
          child: InkWell(
            onTap: () => _selectFact(index),
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
                          ? const Color(0xFF6C5CE7)
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
                        if (!isCompact) ...[
                          const SizedBox(height: 4),
                          Text(
                            fact['fact'] as String? ?? '',
                            style: TextStyle(
                                fontSize: 11,
                                color: Colors.white.withOpacity(0.4)),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.content_copy, size: 14),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(
                          text: fact['fact'] as String? ?? ''));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Copied'),
                            duration: Duration(seconds: 1)),
                      );
                    },
                    style:
                        IconButton.styleFrom(foregroundColor: Colors.white38),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ────────────────────────────────────────────────────────────────
  //  CENTER: COMPOSER
  // ────────────────────────────────────────────────────────────────

  Widget _buildComposer() {
    return Container(
      color: const Color(0xFF0A0A14),
      child: Row(
        children: [
          // ── Center: 9:16 Preview ──
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  // Title bar
                  Row(
                    children: [
                      const Icon(Icons.smart_display,
                          size: 18, color: Color(0xFF6C5CE7)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _composerTitle,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: _isRendering ? null : _renderShort,
                        icon: _isRendering
                            ? SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white.withOpacity(0.7),
                                ),
                              )
                            : const Icon(Icons.bolt, size: 14),
                        label: Text(
                          _isRendering
                              ? '$_progressStage $_progressPercent%'
                              : 'Render',
                          style: const TextStyle(fontSize: 11),
                        ),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // 9:16 phone frame (fixed size — matches 1080×1920 at ¼ scale)
                  Expanded(child: Center(child: _buildPhonePreview())),
                ],
              ),
            ),
          ),
          Container(width: 1, color: Colors.white.withOpacity(0.06)),
          // ── Right: Properties panel ──
          SizedBox(
            width: 280,
            child: _buildPropertiesPanel(),
          ),
        ],
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────
  //  9:16 PHONE PREVIEW
  // ────────────────────────────────────────────────────────────────

  Widget _buildPhonePreview() {
    return SizedBox(
      width: 270,
      height: 480,
      child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.12), width: 2),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final frameW = constraints.maxWidth;
                final frameH = constraints.maxHeight;
                // Text box pixel dimensions
                final boxW = _textBoxW * frameW;
                final boxH = _textBoxH * frameH;
                final boxLeft = (_textPosX * frameW) - (boxW / 2);
                final boxTop = (_textPosY * frameH) - (boxH / 2);

                return Stack(
                  fit: StackFit.expand,
                  children: [
                    // ── Background layer ──
                    if (_bgController != null)
                      Video(
                        controller: _bgController!,
                        controls: NoVideoControls,
                        fit: BoxFit.cover,
                      )
                    else
                      Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0xFF1A1A2E), Color(0xFF0A0A14)],
                          ),
                        ),
                      ),
                    // Dark overlay for readability
                    Container(color: Colors.black.withOpacity(0.3)),

                    // ── Title text (top area) ──
                    Positioned(
                      top: frameH * 0.08,
                      left: 16,
                      right: 16,
                      child: Text(
                        _composerTitle,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: _fontFamily,
                          fontSize: (_fontSize * 0.45).clamp(12, 24),
                          fontWeight: FontWeight.w800,
                          color: Color(_colorHex),
                          shadows: _hasBorder
                              ? const [
                                  Shadow(color: Colors.black, blurRadius: 6),
                                  Shadow(color: Colors.black, blurRadius: 12),
                                ]
                              : null,
                        ),
                      ),
                    ),

                    // ── Resizable text box (draggable + resize handles) ──
                    Positioned(
                      left: boxLeft.clamp(0, frameW - boxW),
                      top: boxTop.clamp(0, frameH - boxH),
                      width: boxW,
                      height: boxH,
                      child: GestureDetector(
                        onPanUpdate: (details) {
                          setState(() {
                            _textPosX = (_textPosX + details.delta.dx / frameW)
                                .clamp(0.1, 0.9);
                            _textPosY = (_textPosY + details.delta.dy / frameH)
                                .clamp(0.1, 0.92);
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: const Color(0xFF6C5CE7).withOpacity(0.5),
                              width: 1.5,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _composerScript,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            maxLines: (boxH / ((_fontSize * 0.3).clamp(8, 16) * 1.5))
                                .floor()
                                .clamp(1, 20),
                            style: TextStyle(
                              fontFamily: _fontFamily,
                              fontSize: (_fontSize * 0.3).clamp(8, 16),
                              fontWeight: FontWeight.w600,
                              color: Color(_colorHex),
                              height: 1.4,
                              shadows: _hasBorder
                                  ? const [
                                      Shadow(color: Colors.black, blurRadius: 4),
                                    ]
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // ── Resize handle: bottom-right corner ──
                    Positioned(
                      left: (boxLeft + boxW - 8).clamp(0, frameW - 16),
                      top: (boxTop + boxH - 8).clamp(0, frameH - 16),
                      child: GestureDetector(
                        onPanUpdate: (details) {
                          setState(() {
                            _textBoxW = (_textBoxW + details.delta.dx / frameW)
                                .clamp(0.3, 0.95);
                            _textBoxH = (_textBoxH + details.delta.dy / frameH)
                                .clamp(0.1, 0.7);
                          });
                        },
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            color: const Color(0xFF6C5CE7),
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(color: Colors.white, width: 1),
                          ),
                          child: const Icon(Icons.open_in_full,
                              size: 10, color: Colors.white),
                        ),
                      ),
                    ),

                    // ── Background indicator (multi-bg) ──
                    if (_selectedBackgrounds.length > 1)
                      Positioned(
                        bottom: 36,
                        left: 0,
                        right: 0,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List.generate(
                            _selectedBackgrounds.length,
                            (i) => GestureDetector(
                              onTap: () {
                                setState(() => _activeBgIndex = i);
                                _loadActiveBgPreview();
                              },
                              child: Container(
                                width: i == _activeBgIndex ? 16 : 6,
                                height: 6,
                                margin: const EdgeInsets.symmetric(horizontal: 2),
                                decoration: BoxDecoration(
                                  color: i == _activeBgIndex
                                      ? const Color(0xFF6C5CE7)
                                      : Colors.white38,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                    // ── Play / Pause toggle ──
                    if (_bgController != null)
                      Positioned(
                        bottom: 8,
                        left: 8,
                        child: GestureDetector(
                          onTap: () {
                            setState(() => _bgPlaying = !_bgPlaying);
                            if (_bgPlaying) {
                              _bgPlayer?.play();
                            } else {
                              _bgPlayer?.pause();
                            }
                          },
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(
                              _bgPlaying ? Icons.pause : Icons.play_arrow,
                              size: 16,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      ),

                    // ── Category badge ──
                    Positioned(
                      bottom: 12,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF6C5CE7).withOpacity(0.6),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _selectedCategory,
                            style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: Colors.white),
                          ),
                        ),
                      ),
                    ),

                    // ── Position presets (right edge) ──
                    Positioned(
                      right: 4,
                      top: frameH * 0.3,
                      child: Column(
                        children: [
                          _previewPosButton(Icons.vertical_align_top, 0.25),
                          _previewPosButton(Icons.vertical_align_center, 0.5),
                          _previewPosButton(Icons.vertical_align_bottom, 0.8),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
      ),
    );
  }

  bool _bgPlaying = true;

  Widget _previewPosButton(IconData icon, double y) {
    final isActive = (_textPosY - y).abs() < 0.08;
    return GestureDetector(
      onTap: () => setState(() => _textPosY = y),
      child: Container(
        width: 22,
        height: 22,
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: isActive
              ? const Color(0xFF6C5CE7).withOpacity(0.6)
              : Colors.black38,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(icon,
            size: 14, color: isActive ? Colors.white : Colors.white38),
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────
  //  RIGHT: PROPERTIES PANEL
  // ────────────────────────────────────────────────────────────────

  Widget _buildPropertiesPanel() {
    return Container(
      color: const Color(0xFF141420),
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // ── Voice section ──
          _sectionHeader('Voice', Icons.record_voice_over),
          const SizedBox(height: 8),
          DropdownButton<TtsVoice>(
            value: _selectedVoice,
            isExpanded: true,
            items: TtsVoice.values
                .map((v) => DropdownMenuItem(
                      value: v,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(v.label, style: const TextStyle(fontSize: 13)),
                          Text(v.description,
                              style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.white.withOpacity(0.3))),
                        ],
                      ),
                    ))
                .toList(),
            onChanged: (v) {
              if (v != null) setState(() => _selectedVoice = v);
            },
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isPreviewingVoice ? null : _previewVoice,
              icon: _isPreviewingVoice
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white.withOpacity(0.4),
                      ),
                    )
                  : Icon(
                      _voicePlaying ? Icons.stop : Icons.play_arrow,
                      size: 16,
                    ),
              label: Text(
                _isPreviewingVoice
                    ? 'Generating...'
                    : _voicePlaying
                        ? 'Playing...'
                        : 'Preview Voice',
                style: const TextStyle(fontSize: 11),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white60,
                side: BorderSide(color: Colors.white.withOpacity(0.12)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Divider(color: Colors.white.withOpacity(0.06)),
          const SizedBox(height: 12),

          // ── Text Style section ──
          _sectionHeader('Text Style', Icons.text_fields),
          const SizedBox(height: 8),
          Text('Font',
              style:
                  TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.4))),
          const SizedBox(height: 4),
          DropdownButton<String>(
            value: _fontFamily,
            isExpanded: true,
            items: [
              'Inter',
              'Roboto',
              'Montserrat',
              'Oswald',
              'Lato',
              'Poppins'
            ]
                .map((f) => DropdownMenuItem(
                    value: f,
                    child: Text(f, style: const TextStyle(fontSize: 12))))
                .toList(),
            onChanged: (v) {
              if (v != null) setState(() => _fontFamily = v);
            },
          ),
          const SizedBox(height: 8),
          Text('Size: ${_fontSize.toInt()}px',
              style:
                  TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.4))),
          Slider(
            value: _fontSize,
            min: 20,
            max: 72,
            divisions: 26,
            onChanged: (v) => setState(() => _fontSize = v),
          ),
          const SizedBox(height: 4),
          Text('Color',
              style:
                  TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.4))),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _colorDot(0xFFFFFFFF),
              _colorDot(0xFFFFD700),
              _colorDot(0xFF6C5CE7),
              _colorDot(0xFF00C853),
              _colorDot(0xFFFF5252),
              _colorDot(0xFF40C4FF),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('Text Shadow',
                  style: TextStyle(
                      fontSize: 11, color: Colors.white.withOpacity(0.5))),
              const Spacer(),
              Switch(
                value: _hasBorder,
                onChanged: (v) => setState(() => _hasBorder = v),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('Text Box Width: ${(_textBoxW * 100).toInt()}%',
              style:
                  TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.4))),
          Slider(
            value: _textBoxW,
            min: 0.3,
            max: 0.95,
            divisions: 13,
            onChanged: (v) => setState(() => _textBoxW = v),
          ),
          Text('Text Box Height: ${(_textBoxH * 100).toInt()}%',
              style:
                  TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.4))),
          Slider(
            value: _textBoxH,
            min: 0.1,
            max: 0.7,
            divisions: 12,
            onChanged: (v) => setState(() => _textBoxH = v),
          ),
          const SizedBox(height: 12),
          Divider(color: Colors.white.withOpacity(0.06)),
          const SizedBox(height: 12),

          // ── Background section (multi-select) ──
          Row(
            children: [
              _sectionHeader('Backgrounds', Icons.image),
              const Spacer(),
              if (_selectedBackgrounds.isNotEmpty)
                Text(
                  '${_selectedBackgrounds.length} selected',
                  style: TextStyle(
                      fontSize: 10, color: Colors.white.withOpacity(0.3)),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Tap to add/remove. Multiple clips cycle during the video.',
            style: TextStyle(
                fontSize: 9, color: Colors.white.withOpacity(0.25)),
          ),
          const SizedBox(height: 8),
          if (_bgResults.isEmpty && !_isSearchingBg)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _visualKeywords.isEmpty
                      ? 'No keywords available'
                      : 'Searching for backgrounds...',
                  style: TextStyle(
                      fontSize: 11, color: Colors.white.withOpacity(0.2)),
                ),
              ),
            ),
          if (_isSearchingBg)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white.withOpacity(0.3),
                  ),
                ),
              ),
            ),
          if (_bgResults.isNotEmpty)
            SizedBox(
              height: 80,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _bgResults.length,
                itemBuilder: (context, index) {
                  final clip = _bgResults[index];
                  final url = clip['preview_url'] as String? ?? '';
                  final dlUrl = clip['download_url'] as String? ?? '';
                  final selectedIdx = _selectedBackgrounds.indexWhere(
                      (b) => b['download_url'] == dlUrl);
                  final isSelected = selectedIdx >= 0;
                  return GestureDetector(
                    onTap: () => _toggleBackground(clip),
                    child: Container(
                      width: 80,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isSelected
                              ? const Color(0xFF6C5CE7)
                              : Colors.white.withOpacity(0.08),
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (url.isNotEmpty)
                              Image.network(url,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Container(
                                      color: Colors.white10,
                                      child: const Icon(Icons.image,
                                          color: Colors.white24, size: 16)))
                            else
                              Container(
                                  color: Colors.white10,
                                  child: const Icon(Icons.image,
                                      color: Colors.white24, size: 16)),
                            // Selection badge with order number
                            if (isSelected)
                              Positioned(
                                top: 4,
                                right: 4,
                                child: Container(
                                  width: 18,
                                  height: 18,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFF6C5CE7),
                                    shape: BoxShape.circle,
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    '${selectedIdx + 1}',
                                    style: const TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          // Selected backgrounds strip (reorderable)
          if (_selectedBackgrounds.length > 1) ...[
            const SizedBox(height: 6),
            SizedBox(
              height: 40,
              child: ReorderableListView(
                scrollDirection: Axis.horizontal,
                buildDefaultDragHandles: false,
                onReorder: (oldIndex, newIndex) {
                  setState(() {
                    if (newIndex > oldIndex) newIndex -= 1;
                    final item = _selectedBackgrounds.removeAt(oldIndex);
                    _selectedBackgrounds.insert(newIndex, item);
                  });
                },
                children: List.generate(_selectedBackgrounds.length, (i) {
                  final bg = _selectedBackgrounds[i];
                  final pUrl = bg['preview_url'] as String? ?? '';
                  return ReorderableDragStartListener(
                    key: ValueKey('bg_order_$i'),
                    index: i,
                    child: Container(
                      width: 40,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: i == _activeBgIndex
                              ? const Color(0xFF6C5CE7)
                              : Colors.white12,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: pUrl.isNotEmpty
                            ? Image.network(pUrl, fit: BoxFit.cover)
                            : Container(color: Colors.white10),
                      ),
                    ),
                  );
                }),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Drag to reorder. Clips play in order.',
                style: TextStyle(
                    fontSize: 8, color: Colors.white.withOpacity(0.2)),
              ),
            ),
          ],
          // Keyword chips for searching different backgrounds
          if (_visualKeywords.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: _visualKeywords.map((kw) {
                return ActionChip(
                  label: Text(kw, style: const TextStyle(fontSize: 10)),
                  onPressed: () => _searchBackgrounds(kw),
                  backgroundColor:
                      const Color(0xFF6C5CE7).withOpacity(0.1),
                  side: BorderSide(
                      color: const Color(0xFF6C5CE7).withOpacity(0.2)),
                  visualDensity: VisualDensity.compact,
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 12),
          Divider(color: Colors.white.withOpacity(0.06)),
          const SizedBox(height: 12),

          // ── Script section ──
          _sectionHeader('Script', Icons.edit_note),
          const SizedBox(height: 8),
          if (_editingScript) ...[
            TextField(
              controller: _scriptEditController,
              maxLines: 6,
              style: const TextStyle(fontSize: 12, height: 1.5),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.all(10),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                FilledButton(
                  onPressed: () {
                    setState(() {
                      _composerScript = _scriptEditController.text;
                      _editingScript = false;
                      _estimatedDuration =
                          (_composerScript.split(' ').length / 2.5)
                              .clamp(10, 90);
                    });
                  },
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                  ),
                  child: const Text('Save', style: TextStyle(fontSize: 11)),
                ),
                const SizedBox(width: 6),
                TextButton(
                  onPressed: () => setState(() => _editingScript = false),
                  child: const Text('Cancel', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.03),
                borderRadius: BorderRadius.circular(8),
                border:
                    Border.all(color: Colors.white.withOpacity(0.06)),
              ),
              child: Text(
                _composerScript,
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withOpacity(0.5),
                    height: 1.5),
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: () {
                  _scriptEditController.text = _composerScript;
                  setState(() => _editingScript = true);
                },
                icon: const Icon(Icons.edit, size: 14),
                label: const Text('Edit Script',
                    style: TextStyle(fontSize: 11)),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white54,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          // Word count + estimated duration
          Row(
            children: [
              Text(
                '${_composerScript.split(' ').length} words',
                style: TextStyle(
                    fontSize: 10, color: Colors.white.withOpacity(0.25)),
              ),
              const Spacer(),
              Text(
                '~${_estimatedDuration.toInt()}s',
                style: TextStyle(
                    fontSize: 10, color: Colors.white.withOpacity(0.25)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 14, color: Colors.white.withOpacity(0.4)),
        const SizedBox(width: 6),
        Text(title,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Colors.white.withOpacity(0.5))),
      ],
    );
  }

  Widget _colorDot(int hex) {
    final isSelected = hex == _colorHex;
    return GestureDetector(
      onTap: () => setState(() => _colorHex = hex),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: Color(hex),
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? Colors.white : Colors.white24,
            width: isSelected ? 3 : 1,
          ),
        ),
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────
  //  BOTTOM: TIMELINE SCRUBBER
  // ────────────────────────────────────────────────────────────────

  Widget _buildTimelineScrubber() {
    final words = _composerScript.split(' ');
    final totalWords = words.length;
    // Create segments: each ~10 words is a "segment" on the timeline
    final segmentCount = (totalWords / 10).ceil().clamp(1, 20);

    return Container(
      height: 80,
      color: const Color(0xFF141420),
      child: Column(
        children: [
          Divider(height: 1, color: Colors.white.withOpacity(0.06)),
          // Track labels + segments
          Expanded(
            child: Row(
              children: [
                // Track labels
                SizedBox(
                  width: 80,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _trackLabel('Voice', Icons.record_voice_over,
                          const Color(0xFF2D824A)),
                      _trackLabel(
                          'Video', Icons.videocam, const Color(0xFF2D5AA0)),
                      _trackLabel(
                          'Text', Icons.text_fields, const Color(0xFF82782D)),
                    ],
                  ),
                ),
                Container(
                    width: 1, color: Colors.white.withOpacity(0.06)),
                // Segment bars + scrubber
                Expanded(
                  child: GestureDetector(
                    onTapDown: (details) {
                      final renderBox =
                          context.findRenderObject() as RenderBox;
                      // Account for the 80px label column
                      final localX =
                          details.localPosition.dx;
                      final totalWidth = renderBox.size.width - 80;
                      setState(() {
                        _scrubPosition =
                            (localX / totalWidth).clamp(0.0, 1.0);
                      });
                    },
                    onPanUpdate: (details) {
                      final renderBox =
                          context.findRenderObject() as RenderBox;
                      final totalWidth = renderBox.size.width - 80;
                      setState(() {
                        _scrubPosition =
                            (_scrubPosition + details.delta.dx / totalWidth)
                                .clamp(0.0, 1.0);
                      });
                    },
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final trackWidth = constraints.maxWidth;
                        return Stack(
                          children: [
                            Column(
                              children: [
                                // Voice track
                                _trackBar(const Color(0xFF2D824A), trackWidth,
                                    _previewAudioPath != null
                                        ? _selectedVoice.label
                                        : 'TTS (${_selectedVoice.label})'),
                                // Video track
                                _trackBar(const Color(0xFF2D5AA0), trackWidth,
                                    _selectedBackgrounds.isNotEmpty
                                        ? '${_selectedBackgrounds.length} clip${_selectedBackgrounds.length > 1 ? 's' : ''} (cycling)'
                                        : 'Gradient background'),
                                // Text track — show segments
                                _trackBarSegmented(
                                    const Color(0xFF82782D),
                                    trackWidth,
                                    segmentCount),
                              ],
                            ),
                            // Playhead
                            Positioned(
                              left: _scrubPosition * trackWidth,
                              top: 0,
                              bottom: 0,
                              child: Container(
                                width: 2,
                                color: Colors.redAccent,
                              ),
                            ),
                            // Scrub handle
                            Positioned(
                              left: _scrubPosition * trackWidth - 6,
                              top: -2,
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: const BoxDecoration(
                                  color: Colors.redAccent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Time labels
          Padding(
            padding: const EdgeInsets.only(left: 80, right: 8, bottom: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatTime(_scrubPosition * _estimatedDuration),
                  style: TextStyle(
                    fontSize: 9,
                    fontFamily: 'monospace',
                    color: Colors.white.withOpacity(0.3),
                  ),
                ),
                Text(
                  _formatTime(_estimatedDuration),
                  style: TextStyle(
                    fontSize: 9,
                    fontFamily: 'monospace',
                    color: Colors.white.withOpacity(0.3),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _trackLabel(String name, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Row(
        children: [
          Icon(icon, size: 10, color: color.withOpacity(0.6)),
          const SizedBox(width: 4),
          Text(name,
              style: TextStyle(
                  fontSize: 9, color: Colors.white.withOpacity(0.4))),
        ],
      ),
    );
  }

  Widget _trackBar(Color color, double width, String label) {
    return Expanded(
      child: Container(
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          border: Border(
              bottom:
                  BorderSide(color: Colors.white.withOpacity(0.04))),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: width * 0.95,
            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: color.withOpacity(0.35),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(label,
                style: const TextStyle(fontSize: 8, color: Colors.white60),
                overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
    );
  }

  Widget _trackBarSegmented(Color color, double width, int segments) {
    return Expanded(
      child: Container(
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          border: Border(
              bottom:
                  BorderSide(color: Colors.white.withOpacity(0.04))),
        ),
        child: Row(
          children: List.generate(segments, (i) {
            return Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(
                    horizontal: 1, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.35),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: i == 0
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text('Caption ${i + 1}',
                            style: const TextStyle(
                                fontSize: 7, color: Colors.white54),
                            overflow: TextOverflow.ellipsis),
                      )
                    : null,
              ),
            );
          }),
        ),
      ),
    );
  }

  String _formatTime(double seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds.toInt() % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
