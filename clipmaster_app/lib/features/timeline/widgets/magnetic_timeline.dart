import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/ipc/ipc_client.dart';
import '../../../core/ipc/ipc_message.dart';
import '../../../core/services/api_key_service.dart';
import '../../../core/services/project_state.dart';

/// The Magnetic Timeline — the core editing UI for ClipMaster Pro.
///
/// Design philosophy:
///   - Non-destructive editing: Auto-Crop and Auto-Caption generate editable
///     objects on the timeline, never "baked-in" effects.
///   - Proxy playback: 720p proxies are used for scrubbing while the original
///     4K VODs are used for final rendering.
///   - Magnetic snapping: clips snap to adjacent edges for fast assembly.
class MagneticTimeline extends ConsumerStatefulWidget {
  const MagneticTimeline({super.key});

  @override
  ConsumerState<MagneticTimeline> createState() => _MagneticTimelineState();
}

class _MagneticTimelineState extends ConsumerState<MagneticTimeline> {
  double _zoomLevel = 1.0;
  double _playheadPosition = 0.0;
  final ScrollController _horizontalScroll = ScrollController();

  // Imported video state
  String? _importedVideoPath;
  String? _importedVideoName;
  bool _isImporting = false;
  String _importStage = '';
  int _importPercent = 0;

  // Proxy state
  String? _proxyPath;
  bool _isGeneratingProxy = false;

  // Transcription state
  List<Map<String, dynamic>> _transcriptSegments = [];
  bool _isTranscribing = false;

  // TTS state
  String? _ttsAudioPath;
  bool _isGeneratingTts = false;

  // Right panel state
  _RightPanel _rightPanel = _RightPanel.none;

  // Stock footage search
  final _stockSearchController = TextEditingController();
  List<Map<String, dynamic>> _stockResults = [];
  bool _isSearchingStock = false;

  // Rendering
  bool _isRendering = false;

  // Preview player
  Player? _previewPlayer;
  VideoController? _previewController;
  bool _previewPlaying = false;

  @override
  void dispose() {
    _horizontalScroll.dispose();
    _stockSearchController.dispose();
    _previewPlayer?.dispose();
    super.dispose();
  }

  void _initPreviewPlayer(String path) {
    if (_previewPlayer != null) {
      _previewPlayer!.dispose();
    }
    _previewPlayer = Player();
    _previewController = VideoController(_previewPlayer!);
    final media = path.startsWith('http') ? Media(path) : Media(path);
    _previewPlayer!.open(media);
    _previewPlayer!.setPlaylistMode(PlaylistMode.loop);
    _previewPlaying = true;
    _previewPlayer!.stream.playing.listen((playing) {
      if (mounted) setState(() => _previewPlaying = playing);
    });
  }

  Future<void> _importVideo() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
    );

    if (result == null || result.files.isEmpty) return;

    final filePath = result.files.first.path;
    if (filePath == null) return;

    setState(() {
      _importedVideoPath = filePath;
      _importedVideoName = result.files.first.name;
      _isImporting = false;
    });
  }

  Future<void> _downloadVideo({String? videoUrl}) async {
    String? url = videoUrl;
    if (url == null) {
      final controller = TextEditingController();
      url = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Download Video'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: 'Paste YouTube or video URL...',
              prefixIcon: Icon(Icons.link),
            ),
            autofocus: true,
            onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text('Download'),
            ),
          ],
        ),
      );
      controller.dispose();
    }
    if (url == null || url.isEmpty) return;

    setState(() {
      _isImporting = true;
      _importStage = 'Starting download';
      _importPercent = 0;
    });

    try {
      final ipc = ref.read(ipcClientProvider);
      final response = await ipc.send(
        IpcMessage(
          type: MessageType.downloadVideo,
          payload: {'url': url},
        ),
        timeout: const Duration(minutes: 10),
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _importStage =
                  progress.payload['stage'] as String? ?? 'Downloading';
              _importPercent = progress.payload['percent'] as int? ?? 0;
            });
          }
        },
      );

      if (response.type == MessageType.error) {
        if (mounted) {
          setState(() => _isImporting = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    response.payload['message'] as String? ?? 'Download failed')),
          );
        }
      } else {
        final filePath = response.payload['file_path'] as String? ?? '';
        if (mounted) {
          setState(() {
            _isImporting = false;
            _importedVideoPath = filePath;
            _importedVideoName = filePath.split(Platform.pathSeparator).last;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isImporting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $e')),
        );
      }
    }
  }

  Future<void> _generateProxy() async {
    if (_importedVideoPath == null) return;

    setState(() {
      _isGeneratingProxy = true;
      _importStage = 'Generating proxy';
      _importPercent = 0;
    });

    try {
      final ipc = ref.read(ipcClientProvider);
      final response = await ipc.send(
        IpcMessage(
          type: MessageType.generateProxy,
          payload: {'source_path': _importedVideoPath},
        ),
        timeout: const Duration(minutes: 15),
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _importStage =
                  progress.payload['stage'] as String? ?? 'Encoding proxy';
              _importPercent = progress.payload['percent'] as int? ?? 0;
            });
          }
        },
      );

      if (response.type == MessageType.error) {
        if (mounted) {
          setState(() => _isGeneratingProxy = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    response.payload['message'] as String? ?? 'Proxy failed')),
          );
        }
      } else {
        if (mounted) {
          setState(() {
            _isGeneratingProxy = false;
            _proxyPath = response.payload['proxy_path'] as String?;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('720p proxy generated successfully')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isGeneratingProxy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Proxy failed: $e')),
        );
      }
    }
  }

  Future<void> _transcribeVideo() async {
    if (_importedVideoPath == null) return;
    final apiService = ref.read(apiKeyServiceProvider);
    final openaiKey = apiService.getNextKey(LlmProvider.openai);
    if (openaiKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('OpenAI API key required for transcription. Add one in Settings.')),
      );
      return;
    }

    setState(() {
      _isTranscribing = true;
      _importStage = 'Transcribing';
      _importPercent = 0;
    });

    try {
      final ipc = ref.read(ipcClientProvider);
      final response = await ipc.send(
        IpcMessage(
          type: MessageType.transcribe,
          payload: {
            'audio_path': _importedVideoPath,
            'api_key': openaiKey,
          },
        ),
        timeout: const Duration(minutes: 10),
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _importStage =
                  progress.payload['stage'] as String? ?? 'Transcribing';
              _importPercent = progress.payload['percent'] as int? ?? 0;
            });
          }
        },
      );

      if (response.type == MessageType.error) {
        if (mounted) {
          setState(() => _isTranscribing = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(response.payload['message'] as String? ??
                    'Transcription failed')),
          );
        }
      } else {
        if (mounted) {
          final segments =
              (response.payload['segments'] as List<dynamic>? ?? [])
                  .cast<Map<String, dynamic>>();
          setState(() {
            _isTranscribing = false;
            _transcriptSegments = segments;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    'Transcription complete: ${segments.length} segments')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isTranscribing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Transcription failed: $e')),
        );
      }
    }
  }

  Future<void> _searchStockFootage() async {
    final query = _stockSearchController.text.trim();
    if (query.isEmpty) return;

    final apiService = ref.read(apiKeyServiceProvider);
    final pexelsKey = apiService.getNextKey(LlmProvider.pexels);
    final pixabayKey = apiService.getNextKey(LlmProvider.pixabay);

    if (pexelsKey == null && pixabayKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Add a Pexels or Pixabay API key in Settings.')),
      );
      return;
    }

    setState(() {
      _isSearchingStock = true;
      _stockResults = [];
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
            'per_source': 6,
          },
        ),
        timeout: const Duration(seconds: 20),
      );

      if (mounted) {
        if (response.type == MessageType.error) {
          setState(() => _isSearchingStock = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(response.payload['message'] as String? ??
                    'Search failed')),
          );
        } else {
          final clips =
              (response.payload['clips'] as List<dynamic>? ?? [])
                  .cast<Map<String, dynamic>>();
          setState(() {
            _isSearchingStock = false;
            _stockResults = clips;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSearchingStock = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Search failed: $e')),
        );
      }
    }
  }

  Future<void> _renderVideo() async {
    final project = ref.read(projectProvider);
    if (project.scriptText == null || project.scriptText!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No script loaded. Use Fact Shorts to generate content.')),
      );
      return;
    }

    final apiService = ref.read(apiKeyServiceProvider);
    final openaiKey = apiService.getNextKey(LlmProvider.openai);
    if (openaiKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('OpenAI API key required. Add one in Settings.')),
      );
      return;
    }

    final docsDir = await getApplicationDocumentsDirectory();
    final shortsDir = Directory(
      '${docsDir.path}${Platform.pathSeparator}ClipMasterPro${Platform.pathSeparator}shorts',
    );
    if (!shortsDir.existsSync()) {
      await shortsDir.create(recursive: true);
    }

    setState(() {
      _isRendering = true;
      _importStage = 'Rendering short';
      _importPercent = 0;
    });

    try {
      final ipc = ref.read(ipcClientProvider);
      final visualKeywords = project.assets
          .where((a) => a.track == TimelineTrack.broll)
          .map((a) => a.label)
          .toList();

      final pexelsKey = apiService.getNextKey(LlmProvider.pexels);
      final pixabayKey = apiService.getNextKey(LlmProvider.pixabay);

      final payload = <String, dynamic>{
        'text': project.scriptText,
        'title': project.scriptTitle ?? 'Untitled',
        'api_key': openaiKey,
        'voice': project.selectedVoice.name,
        'output_dir': shortsDir.path,
        'visual_keywords': visualKeywords,
        if (pexelsKey != null) 'pexels_key': pexelsKey,
        if (pixabayKey != null) 'pixabay_key': pixabayKey,
      };

      final response = await ipc.send(
        IpcMessage(type: MessageType.createShort, payload: payload),
        timeout: const Duration(minutes: 5),
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _importStage =
                  progress.payload['stage'] as String? ?? 'Rendering';
              _importPercent = progress.payload['percent'] as int? ?? 0;
            });
          }
        },
      );

      if (!mounted) return;

      if (response.type == MessageType.error) {
        setState(() => _isRendering = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  response.payload['message'] as String? ?? 'Render failed')),
        );
      } else {
        final outputPath = response.payload['output_path'] as String? ?? '';
        final duration =
            (response.payload['duration'] as num?)?.toDouble() ?? 0;
        setState(() => _isRendering = false);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Short rendered! ${duration.toStringAsFixed(0)}s video saved.',
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
        setState(() => _isRendering = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Render failed: $e')),
        );
      }
    }
  }

  bool get _isBusy =>
      _isImporting ||
      _isGeneratingProxy ||
      _isTranscribing ||
      _isGeneratingTts ||
      _isRendering;

  @override
  Widget build(BuildContext context) {
    final project = ref.watch(projectProvider);

    // Auto-pick up video from project state if we don't have one imported.
    if (_importedVideoPath == null && !_isImporting) {
      final videoAsset = project.assets
          .where((a) => a.track == TimelineTrack.video)
          .firstOrNull;
      if (videoAsset != null) {
        if (videoAsset.filePath != null) {
          _importedVideoPath = videoAsset.filePath;
          _importedVideoName = videoAsset.label;
        } else if (videoAsset.url != null && videoAsset.url!.isNotEmpty) {
          // Auto-download from URL.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _downloadVideo(videoUrl: videoAsset.url);
          });
        }
      }
    }

    // Pick up TTS audio from project state.
    final audioAsset = project.assets
        .where((a) => a.track == TimelineTrack.audio)
        .firstOrNull;
    if (audioAsset?.filePath != null && _ttsAudioPath == null) {
      _ttsAudioPath = audioAsset!.filePath;
    }

    return Row(
      children: [
        // Main timeline area
        Expanded(
          child: Column(
            children: [
              // Top bar: video preview + controls + script
              Expanded(
                flex: 3,
                child: Container(
                  color: const Color(0xFF0A0A14),
                  child: _importedVideoPath == null && project.scriptText == null
                      ? _buildEmptyPreview()
                      : _buildProjectView(project),
                ),
              ),
              const Divider(height: 1),
              _buildTimelineToolbar(project),
              const Divider(height: 1),
              // Progress bar (when busy)
              if (_isBusy)
                Container(
                  color: const Color(0xFF1E1E2E),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white.withOpacity(0.5),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '$_importStage... $_importPercent%',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withOpacity(0.5),
                        ),
                      ),
                      const Spacer(),
                      SizedBox(
                        width: 120,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: _importPercent / 100,
                            backgroundColor: Colors.white10,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const Divider(height: 1),
              // Timeline tracks
              Expanded(
                flex: 2,
                child: _buildTimelineTracks(project),
              ),
            ],
          ),
        ),
        // Right side panel (stock footage / text editor)
        if (_rightPanel != _RightPanel.none) ...[
          Container(width: 1, color: Colors.white.withOpacity(0.06)),
          SizedBox(
            width: 320,
            child: _rightPanel == _RightPanel.stockFootage
                ? _buildStockFootagePanel()
                : _rightPanel == _RightPanel.textEditor
                    ? _buildTextEditorPanel(project)
                    : _buildVoicePanel(project),
          ),
        ],
      ],
    );
  }

  Widget _buildEmptyPreview() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.play_circle_outline,
              size: 56, color: Colors.white.withOpacity(0.08)),
          const SizedBox(height: 12),
          Text(
            'Import a video or create a short from Fact Shorts',
            style: TextStyle(
              color: Colors.white.withOpacity(0.15),
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.icon(
                onPressed: _importVideo,
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('Import File'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _downloadVideo,
                icon: const Icon(Icons.download, size: 18),
                label: const Text('Download URL'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: BorderSide(color: Colors.white.withOpacity(0.2)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProjectView(ProjectState project) {
    // Auto-init preview player when we have a video file
    final previewSource = _proxyPath ?? _importedVideoPath;
    if (previewSource != null && _previewPlayer == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _initPreviewPlayer(previewSource);
        setState(() {});
      });
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Left: 9:16 Phone Frame Preview with draggable text ──
          _buildPhonePreview(project),
          const SizedBox(width: 20),
          // ── Right: controls + script ──
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_importedVideoPath != null) ...[
                  Row(
                    children: [
                      const Icon(Icons.videocam,
                          color: Color(0xFF6C5CE7), size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _importedVideoName ?? 'Video',
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      _ActionButton(
                        icon: Icons.folder_open,
                        label: 'Replace',
                        onPressed: _isBusy ? null : _importVideo,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                // Quick-action chips
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (_importedVideoPath != null) ...[
                      _buildActionChip(
                        icon: Icons.high_quality,
                        label: _proxyPath != null
                            ? 'Proxy Ready'
                            : 'Generate Proxy',
                        color: _proxyPath != null
                            ? const Color(0xFF00C853)
                            : const Color(0xFF6C5CE7),
                        busy: _isGeneratingProxy,
                        onTap: _isBusy || _proxyPath != null
                            ? null
                            : _generateProxy,
                      ),
                      _buildActionChip(
                        icon: Icons.subtitles,
                        label: _transcriptSegments.isNotEmpty
                            ? '${_transcriptSegments.length} Captions'
                            : 'Transcribe',
                        color: _transcriptSegments.isNotEmpty
                            ? const Color(0xFF00C853)
                            : const Color(0xFF6C5CE7),
                        busy: _isTranscribing,
                        onTap: _isBusy || _transcriptSegments.isNotEmpty
                            ? null
                            : _transcribeVideo,
                      ),
                    ],
                    _buildActionChip(
                      icon: Icons.movie_filter,
                      label: 'Stock Footage',
                      color: _rightPanel == _RightPanel.stockFootage
                          ? const Color(0xFF00C853)
                          : const Color(0xFF5A2D82),
                      busy: false,
                      onTap: () => setState(() {
                        _rightPanel = _rightPanel == _RightPanel.stockFootage
                            ? _RightPanel.none
                            : _RightPanel.stockFootage;
                      }),
                    ),
                    if (project.scriptText != null) ...[
                      _buildActionChip(
                        icon: Icons.text_fields,
                        label: 'Text / Font',
                        color: _rightPanel == _RightPanel.textEditor
                            ? const Color(0xFF00C853)
                            : const Color(0xFF82782D),
                        busy: false,
                        onTap: () => setState(() {
                          _rightPanel = _rightPanel == _RightPanel.textEditor
                              ? _RightPanel.none
                              : _RightPanel.textEditor;
                        }),
                      ),
                      _buildActionChip(
                        icon: Icons.record_voice_over,
                        label: project.selectedVoice.label,
                        color: _rightPanel == _RightPanel.voicePicker
                            ? const Color(0xFF00C853)
                            : const Color(0xFF2D824A),
                        busy: false,
                        onTap: () => setState(() {
                          _rightPanel = _rightPanel == _RightPanel.voicePicker
                              ? _RightPanel.none
                              : _RightPanel.voicePicker;
                        }),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                // Script preview
                if (project.scriptText != null) ...[
                  Row(
                    children: [
                      Text(
                        project.scriptTitle ?? 'Script',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF6C5CE7),
                        ),
                      ),
                      const Spacer(),
                      if (_ttsAudioPath != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00C853).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'TTS Ready',
                            style: TextStyle(
                                fontSize: 10, color: Color(0xFF00C853)),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.03),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: Colors.white.withOpacity(0.06)),
                      ),
                      child: SingleChildScrollView(
                        child: Text(
                          project.scriptText!,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.6,
                            color: Colors.white.withOpacity(0.7),
                          ),
                        ),
                      ),
                    ),
                  ),
                ] else if (_transcriptSegments.isNotEmpty) ...[
                  Text(
                    'Transcript Preview',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withOpacity(0.5),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _transcriptSegments.length,
                      itemBuilder: (context, index) {
                        final seg = _transcriptSegments[index];
                        final start =
                            (seg['start'] as num?)?.toDouble() ?? 0;
                        final text = seg['text'] as String? ?? '';
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 60,
                                child: Text(
                                  _formatTime(start),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    color: Colors.white.withOpacity(0.3),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  text,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.white.withOpacity(0.6),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ] else ...[
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.movie_creation,
                              size: 32,
                              color: Colors.white.withOpacity(0.1)),
                          const SizedBox(height: 8),
                          Text(
                            'Use Fact Shorts to generate a script,\nor import a video and transcribe it.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withOpacity(0.2),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          // Right: B-roll thumbnails from project
          if (project.assets
              .where((a) => a.track == TimelineTrack.broll)
              .isNotEmpty) ...[
            const SizedBox(width: 16),
            SizedBox(
              width: 140,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'B-Roll (${project.assets.where((a) => a.track == TimelineTrack.broll).length})',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withOpacity(0.5),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView(
                      children: project.assets
                          .where((a) => a.track == TimelineTrack.broll)
                          .map((a) => _buildBrollThumb(a))
                          .toList(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 9:16 phone-frame preview with live video + draggable text overlay.
  /// Matches the Fact Shorts composer layout: title at top, script body
  /// at positionY, stock footage or gradient background.
  Widget _buildPhonePreview(ProjectState project) {
    final style = project.captionStyle;
    final titleText = project.scriptTitle ?? '';
    final scriptText = project.scriptText ?? '';
    final hasTitle = titleText.isNotEmpty;
    final hasScript = scriptText.isNotEmpty;

    // Check if there's a video-track asset with a URL (stock footage from composer)
    final videoAssets =
        project.assets.where((a) => a.track == TimelineTrack.video).toList();
    final bgUrl = videoAssets.isNotEmpty
        ? (videoAssets.first.url ?? videoAssets.first.thumbnailUrl ?? '')
        : '';

    // Auto-load background from URL if no local video is loaded
    if (bgUrl.isNotEmpty && _previewController == null) {
      _initPreviewPlayer(bgUrl);
    }

    return SizedBox(
      width: 200,
      child: Column(
        children: [
          // Phone frame header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: const BoxDecoration(
              color: Color(0xFF1A1A2A),
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          ),
          // Phone frame body — 9:16 aspect ratio
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0A0A14),
                border: Border.all(
                  color: Colors.white.withOpacity(0.1),
                  width: 2,
                ),
              ),
              child: ClipRect(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final frameW = constraints.maxWidth;
                    final frameH = constraints.maxHeight;

                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        // Background layer: video or gradient
                        if (_previewController != null)
                          Video(
                            controller: _previewController!,
                            controls: NoVideoControls,
                            fit: BoxFit.cover,
                          )
                        else
                          Container(
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Color(0xFF1A1A2E),
                                  Color(0xFF0A0A14),
                                ],
                              ),
                            ),
                          ),
                        // Dark overlay for readability
                        if (_previewController != null)
                          Container(color: Colors.black.withOpacity(0.3)),
                        // Title text (top area — matches Fact Shorts at 8%)
                        if (hasTitle)
                          Positioned(
                            top: frameH * 0.08,
                            left: 8,
                            right: 8,
                            child: Text(
                              titleText,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: style.fontFamily,
                                fontSize: (style.fontSize * 0.45).clamp(10, 20),
                                fontWeight: FontWeight.w800,
                                color: Color(style.colorHex),
                                shadows: style.hasBorder
                                    ? const [
                                        Shadow(
                                            color: Colors.black, blurRadius: 6),
                                        Shadow(
                                            color: Colors.black,
                                            blurRadius: 12),
                                      ]
                                    : null,
                              ),
                            ),
                          ),
                        // Script body text (draggable position)
                        if (hasScript)
                          Positioned(
                            top: style.positionY * frameH - 30,
                            left: 8,
                            right: 8,
                            child: GestureDetector(
                              onPanUpdate: (details) {
                                final newY =
                                    (style.positionY + details.delta.dy / frameH)
                                        .clamp(0.15, 0.92);
                                ref
                                    .read(projectProvider.notifier)
                                    .setCaptionStyle(style.copyWith(
                                      positionY: newY,
                                    ));
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 3),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: const Color(0xFF6C5CE7)
                                        .withOpacity(0.3),
                                  ),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  scriptText,
                                  textAlign: TextAlign.center,
                                  maxLines: 6,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: style.fontFamily,
                                    fontSize:
                                        (style.fontSize * 0.3).clamp(7, 14),
                                    fontWeight: FontWeight.w600,
                                    color: Color(style.colorHex),
                                    height: 1.4,
                                    shadows: style.hasBorder
                                        ? const [
                                            Shadow(
                                                color: Colors.black,
                                                blurRadius: 4),
                                          ]
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        // Position presets (top / center / bottom)
                        if (hasScript)
                          Positioned(
                            right: 4,
                            top: frameH * 0.3,
                            child: Column(
                              children: [
                                _posPresetButton(
                                    Icons.vertical_align_top, 0.5, 0.25, style),
                                _posPresetButton(Icons.vertical_align_center,
                                    0.5, 0.5, style),
                                _posPresetButton(Icons.vertical_align_bottom,
                                    0.5, 0.8, style),
                              ],
                            ),
                          ),
                        // Play/pause button
                        if (_previewPlayer != null)
                          Positioned(
                            left: 4,
                            bottom: 4,
                            child: GestureDetector(
                              onTap: () => _previewPlayer!.playOrPause(),
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Icon(
                                  _previewPlaying
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                  size: 16,
                                  color: Colors.white70,
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          // Phone frame footer
          Container(
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: const BoxDecoration(
              color: Color(0xFF1A1A2A),
              borderRadius:
                  BorderRadius.vertical(bottom: Radius.circular(16)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '9:16 Preview',
                  style: TextStyle(
                    fontSize: 9,
                    color: Colors.white.withOpacity(0.2),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _posPresetButton(
      IconData icon, double x, double y, CaptionStyle current) {
    final isActive =
        (current.positionX - x).abs() < 0.1 &&
        (current.positionY - y).abs() < 0.1;
    return GestureDetector(
      onTap: () {
        ref.read(projectProvider.notifier).setCaptionStyle(
          current.copyWith(positionX: x, positionY: y),
        );
      },
      child: Container(
        width: 22,
        height: 22,
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: isActive
              ? const Color(0xFF6C5CE7).withOpacity(0.6)
              : Colors.black45,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(icon, size: 14,
            color: isActive ? Colors.white : Colors.white38),
      ),
    );
  }

  Widget _buildBrollThumb(TimelineAsset asset) {
    final previewUrl = asset.thumbnailUrl ??
        asset.metadata['preview_url'] as String? ??
        '';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 140,
              height: 80,
              child: previewUrl.isNotEmpty
                  ? Image.network(
                      previewUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: Colors.white10,
                        child: const Icon(Icons.movie_filter,
                            color: Colors.white24),
                      ),
                    )
                  : Container(
                      color: Colors.white10,
                      child: const Icon(Icons.movie_filter,
                          color: Colors.white24),
                    ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  asset.label,
                  style: const TextStyle(fontSize: 10, color: Colors.white54),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              InkWell(
                onTap: () =>
                    ref.read(projectProvider.notifier).removeAsset(asset.id),
                child: const Icon(Icons.close, size: 14, color: Colors.white38),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineTracks(ProjectState project) {
    final brollAssets =
        project.assets.where((a) => a.track == TimelineTrack.broll).toList();

    return Container(
      color: const Color(0xFF141420),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Row(
              children: [
                // Track labels column
                SizedBox(
                  width: 100,
                  child: Column(
                    children: [
                      _buildTrackLabel('Video', Icons.videocam),
                      _buildTrackLabel('B-Roll', Icons.movie_filter),
                      _buildTrackLabel('Audio', Icons.audiotrack),
                      _buildTrackLabel('Captions', Icons.subtitles),
                      _buildTrackLabel('Crops', Icons.crop),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                // Scrollable track area
                Expanded(
                  child: SingleChildScrollView(
                    controller: _horizontalScroll,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: 2000 * _zoomLevel,
                      child: Stack(
                        children: [
                          Column(
                            children: [
                              _buildTrackRow(
                                const Color(0xFF2D5AA0),
                                hasClip: _importedVideoPath != null,
                                clipLabel: _importedVideoName,
                              ),
                              _buildTrackRow(
                                const Color(0xFF5A2D82),
                                hasClip: brollAssets.isNotEmpty,
                                clipLabel: brollAssets.isNotEmpty
                                    ? '${brollAssets.length} B-Roll clips'
                                    : null,
                              ),
                              _buildTrackRow(
                                const Color(0xFF2D824A),
                                hasClip: _ttsAudioPath != null,
                                clipLabel: _ttsAudioPath != null
                                    ? 'Voiceover (${project.selectedVoice.label})'
                                    : null,
                              ),
                              _buildTrackRow(
                                const Color(0xFF82782D),
                                hasClip: _transcriptSegments.isNotEmpty ||
                                    project.scriptText != null,
                                clipLabel: _transcriptSegments.isNotEmpty
                                    ? '${_transcriptSegments.length} captions'
                                    : project.scriptText != null
                                        ? 'Script captions'
                                        : null,
                              ),
                              _buildTrackRow(const Color(0xFF822D5A)),
                            ],
                          ),
                          // Playhead
                          Positioned(
                            left: _playheadPosition * _zoomLevel,
                            top: 0,
                            bottom: 0,
                            child: Container(
                              width: 2,
                              color: Colors.redAccent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Right panels ───

  Widget _buildStockFootagePanel() {
    return Container(
      color: const Color(0xFF1A1A2A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.movie_filter,
                        size: 18, color: Color(0xFF5A2D82)),
                    const SizedBox(width: 8),
                    const Text('Stock Footage',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () =>
                          setState(() => _rightPanel = _RightPanel.none),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _stockSearchController,
                        decoration: const InputDecoration(
                          hintText: 'Search clips...',
                          prefixIcon: Icon(Icons.search, size: 18),
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                        ),
                        onSubmitted: (_) => _searchStockFootage(),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _isSearchingStock ? null : _searchStockFootage,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                      ),
                      child: _isSearchingStock
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Search', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _stockResults.isEmpty
                ? Center(
                    child: Text(
                      _isSearchingStock
                          ? 'Searching...'
                          : 'Search for royalty-free clips\nfrom Pexels and Pixabay.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.3),
                      ),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(8),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      childAspectRatio: 1.3,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: _stockResults.length,
                    itemBuilder: (context, index) {
                      final clip = _stockResults[index];
                      return _buildStockClipCard(clip);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildStockClipCard(Map<String, dynamic> clip) {
    final previewUrl = clip['preview_url'] as String? ?? '';
    final source = clip['source'] as String? ?? '';
    final keyword = clip['keyword'] as String? ?? '';
    final duration = (clip['duration'] as num?)?.toDouble() ?? 0;

    return InkWell(
      onTap: () {
        ref.read(projectProvider.notifier).addAsset(TimelineAsset(
          id: 'stock_${clip['clip_id'] ?? DateTime.now().millisecondsSinceEpoch}',
          track: TimelineTrack.broll,
          label: keyword.isNotEmpty ? keyword : 'B-Roll',
          url: clip['download_url'] as String?,
          thumbnailUrl: previewUrl,
          metadata: clip,
        ));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Added to B-Roll track'),
            duration: Duration(seconds: 1),
          ),
        );
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withOpacity(0.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(8)),
                child: previewUrl.isNotEmpty
                    ? Image.network(
                        previewUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: Colors.white10,
                          child: const Icon(Icons.movie_filter,
                              color: Colors.white24),
                        ),
                      )
                    : Container(
                        color: Colors.white10,
                        child: const Icon(Icons.movie_filter,
                            color: Colors.white24),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      source.toUpperCase(),
                      style: TextStyle(
                        fontSize: 9,
                        color: Colors.white.withOpacity(0.4),
                      ),
                    ),
                  ),
                  if (duration > 0)
                    Text(
                      '${duration.toStringAsFixed(0)}s',
                      style: TextStyle(
                        fontSize: 9,
                        color: Colors.white.withOpacity(0.4),
                      ),
                    ),
                  const SizedBox(width: 4),
                  const Icon(Icons.add_circle_outline,
                      size: 14, color: Color(0xFF6C5CE7)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextEditorPanel(ProjectState project) {
    final style = project.captionStyle;

    return Container(
      color: const Color(0xFF1A1A2A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Icon(Icons.text_fields,
                    size: 18, color: Color(0xFF82782D)),
                const SizedBox(width: 8),
                const Text('Text & Font',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () =>
                      setState(() => _rightPanel = _RightPanel.none),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Font Family',
                      style: TextStyle(fontSize: 11, color: Colors.white54)),
                  const SizedBox(height: 6),
                  DropdownButton<String>(
                    value: style.fontFamily,
                    isExpanded: true,
                    items: ['Inter', 'Roboto', 'Montserrat', 'Oswald', 'Lato', 'Poppins']
                        .map((f) => DropdownMenuItem(
                            value: f,
                            child: Text(f, style: const TextStyle(fontSize: 13))))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) {
                        ref.read(projectProvider.notifier).setCaptionStyle(
                          style.copyWith(fontFamily: v),
                        );
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  const Text('Font Size',
                      style: TextStyle(fontSize: 11, color: Colors.white54)),
                  Slider(
                    value: style.fontSize,
                    min: 20,
                    max: 72,
                    divisions: 26,
                    label: '${style.fontSize.toInt()}px',
                    onChanged: (v) {
                      ref.read(projectProvider.notifier).setCaptionStyle(
                        style.copyWith(fontSize: v),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  const Text('Text Color',
                      style: TextStyle(fontSize: 11, color: Colors.white54)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _colorCircle(0xFFFFFFFF, style.colorHex, (c) {
                        ref.read(projectProvider.notifier).setCaptionStyle(
                          style.copyWith(colorHex: c),
                        );
                      }),
                      _colorCircle(0xFFFFD700, style.colorHex, (c) {
                        ref.read(projectProvider.notifier).setCaptionStyle(
                          style.copyWith(colorHex: c),
                        );
                      }),
                      _colorCircle(0xFF6C5CE7, style.colorHex, (c) {
                        ref.read(projectProvider.notifier).setCaptionStyle(
                          style.copyWith(colorHex: c),
                        );
                      }),
                      _colorCircle(0xFF00C853, style.colorHex, (c) {
                        ref.read(projectProvider.notifier).setCaptionStyle(
                          style.copyWith(colorHex: c),
                        );
                      }),
                      _colorCircle(0xFFFF5252, style.colorHex, (c) {
                        ref.read(projectProvider.notifier).setCaptionStyle(
                          style.copyWith(colorHex: c),
                        );
                      }),
                      _colorCircle(0xFF40C4FF, style.colorHex, (c) {
                        ref.read(projectProvider.notifier).setCaptionStyle(
                          style.copyWith(colorHex: c),
                        );
                      }),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    title: const Text('Text Border',
                        style: TextStyle(fontSize: 13)),
                    value: style.hasBorder,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (v) {
                      ref.read(projectProvider.notifier).setCaptionStyle(
                        style.copyWith(hasBorder: v),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  const Text('Text Position',
                      style: TextStyle(fontSize: 11, color: Colors.white54)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _posChip('Top', 0.5, 0.12, style),
                      const SizedBox(width: 6),
                      _posChip('Center', 0.5, 0.5, style),
                      const SizedBox(width: 6),
                      _posChip('Bottom', 0.5, 0.85, style),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Or drag the text in the preview.',
                    style: TextStyle(
                        fontSize: 10,
                        color: Colors.white.withOpacity(0.2)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _posChip(String label, double x, double y, CaptionStyle style) {
    final isActive =
        (style.positionX - x).abs() < 0.1 &&
        (style.positionY - y).abs() < 0.1;
    return Expanded(
      child: InkWell(
        onTap: () {
          ref.read(projectProvider.notifier).setCaptionStyle(
            style.copyWith(positionX: x, positionY: y),
          );
        },
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: isActive
                ? const Color(0xFF6C5CE7).withOpacity(0.2)
                : Colors.white.withOpacity(0.04),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isActive
                  ? const Color(0xFF6C5CE7)
                  : Colors.white.withOpacity(0.08),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
              color: isActive
                  ? const Color(0xFF6C5CE7)
                  : Colors.white54,
            ),
          ),
        ),
      ),
    );
  }

  Widget _colorCircle(
      int colorHex, int selectedHex, ValueChanged<int> onTap) {
    final isSelected = colorHex == selectedHex;
    return GestureDetector(
      onTap: () => onTap(colorHex),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: Color(colorHex),
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? Colors.white : Colors.white24,
            width: isSelected ? 3 : 1,
          ),
        ),
      ),
    );
  }

  Widget _buildVoicePanel(ProjectState project) {
    return Container(
      color: const Color(0xFF1A1A2A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Icon(Icons.record_voice_over,
                    size: 18, color: Color(0xFF2D824A)),
                const SizedBox(width: 8),
                const Text('Voice',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () =>
                      setState(() => _rightPanel = _RightPanel.none),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: TtsVoice.values.map((voice) {
                final isSelected = project.selectedVoice == voice;
                return Card(
                  color: isSelected
                      ? const Color(0xFF6C5CE7).withOpacity(0.15)
                      : null,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: isSelected
                        ? const BorderSide(color: Color(0xFF6C5CE7), width: 2)
                        : BorderSide.none,
                  ),
                  child: ListTile(
                    leading: Icon(
                      Icons.record_voice_over,
                      color: isSelected
                          ? const Color(0xFF6C5CE7)
                          : Colors.white38,
                    ),
                    title: Text(voice.label,
                        style: const TextStyle(fontSize: 14)),
                    subtitle: Text(voice.description,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white38)),
                    selected: isSelected,
                    onTap: () {
                      ref.read(projectProvider.notifier).setVoice(voice);
                    },
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Shared helpers ───

  String _formatTime(double seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds.toInt() % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _buildActionChip({
    required IconData icon,
    required String label,
    required Color color,
    required bool busy,
    VoidCallback? onTap,
  }) {
    return ActionChip(
      avatar: busy
          ? SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: color,
              ),
            )
          : Icon(icon, size: 16, color: color),
      label: Text(
        label,
        style: TextStyle(fontSize: 12, color: color),
      ),
      onPressed: onTap,
      backgroundColor: color.withOpacity(0.1),
      side: BorderSide(color: color.withOpacity(0.2)),
    );
  }

  Widget _buildTimelineToolbar(ProjectState project) {
    return Container(
      height: 40,
      color: const Color(0xFF141420),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.skip_previous, size: 20),
            onPressed: () => setState(() => _playheadPosition = 0),
            tooltip: 'Go to start',
          ),
          IconButton(
            icon: const Icon(Icons.play_arrow, size: 20),
            onPressed: () {},
            tooltip: 'Play/Pause',
          ),
          IconButton(
            icon: const Icon(Icons.skip_next, size: 20),
            onPressed: () {},
            tooltip: 'Go to end',
          ),
          const SizedBox(width: 16),
          const Text('Zoom:', style: TextStyle(fontSize: 12)),
          SizedBox(
            width: 150,
            child: Slider(
              value: _zoomLevel,
              min: 0.25,
              max: 4.0,
              onChanged: (v) => setState(() => _zoomLevel = v),
            ),
          ),
          const Spacer(),
          FilterChip(
            label: const Text('Magnetic Snap', style: TextStyle(fontSize: 11)),
            selected: true,
            onSelected: (_) {},
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: Text(
              _proxyPath != null ? 'Proxy Mode (ON)' : 'Proxy Mode',
              style: const TextStyle(fontSize: 11),
            ),
            selected: _proxyPath != null,
            onSelected: (_) {},
          ),
          if (project.scriptText != null) ...[
            const SizedBox(width: 16),
            FilledButton.icon(
              onPressed: _isBusy ? null : _renderVideo,
              icon: _isRendering
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.movie_creation, size: 18),
              label: Text(_isRendering ? 'Rendering...' : 'Render Short'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTrackLabel(String name, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.white10)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: Colors.white54),
            const SizedBox(width: 4),
            Text(
              name,
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrackRow(Color color,
      {bool hasClip = false, String? clipLabel}) {
    return Expanded(
      child: Container(
        decoration: BoxDecoration(
          border: const Border(bottom: BorderSide(color: Colors.white10)),
          color: color.withOpacity(0.1),
        ),
        child: hasClip && clipLabel != null
            ? Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(
                      horizontal: 4, vertical: 3),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: color.withOpacity(0.6)),
                  ),
                  child: Text(
                    clipLabel,
                    style:
                        const TextStyle(fontSize: 10, color: Colors.white70),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
            : const SizedBox.expand(),
      ),
    );
  }
}

enum _RightPanel { none, stockFootage, textEditor, voicePicker }

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  const _ActionButton({
    required this.icon,
    required this.label,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: TextButton.styleFrom(
        foregroundColor: Colors.white54,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
    );
  }
}
