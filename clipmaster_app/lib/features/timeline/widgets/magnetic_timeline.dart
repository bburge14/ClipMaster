import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
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
import '../../../core/utils/time_format.dart';
import '../../../main.dart' show selectedTabProvider;
import '../../fact_shorts/widgets/fact_shorts_page.dart';

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
  // Use ValueNotifiers instead of setState for high-frequency stream updates
  // so only the transport bar rebuilds — NOT the entire widget tree.
  final ValueNotifier<bool> _previewPlayingNotifier = ValueNotifier(false);
  final ValueNotifier<Duration> _previewPositionNotifier = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _previewDurationNotifier = ValueNotifier(Duration.zero);
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _playingSub;

  // Resizable timeline panel height
  double _timelinePanelHeight = 280.0;
  static const double _minTimelineHeight = 160.0;
  static const double _maxTimelineHeight = 600.0;

  // Selected asset for property editing
  String? _selectedAssetId;

  // Which text element is selected in the preview (title vs body)
  _SelectedTextElement _selectedTextElement = _SelectedTextElement.none;

  // Timeline clip dragging state
  String? _draggingAssetId;

  // Snap to grid
  bool _snapEnabled = true;
  static const double _snapIntervalSec = 0.5; // snap to half-second grid

  // Editor tool mode
  _EditorTool _activeTool = _EditorTool.select;

  // Pixels-per-second for the timeline (driven by zoom)
  static const double _basePixelsPerSec = 20.0;
  double get _pixelsPerSec => _basePixelsPerSec * _zoomLevel;

  // Clipboard for copy/paste
  TimelineAsset? _clipboardAsset;

  /// Snap a time value to the nearest grid point if snapping is enabled.
  double _snapTime(double sec) {
    if (!_snapEnabled) return sec;
    return (sec / _snapIntervalSec).round() * _snapIntervalSec;
  }

  /// Split the selected asset at the current playhead position.
  void _splitAtPlayhead() {
    if (_selectedAssetId == null) return;
    final project = ref.read(projectProvider);
    final asset = project.assets.where((a) => a.id == _selectedAssetId).firstOrNull;
    if (asset == null) return;

    final playheadSec = _playheadPosition / _basePixelsPerSec;
    if (playheadSec <= asset.startSec || playheadSec >= asset.startSec + (asset.durationSec > 0 ? asset.durationSec : 10.0)) return;

    final firstDuration = playheadSec - asset.startSec;
    final origDuration = asset.durationSec > 0 ? asset.durationSec : 10.0;
    final secondDuration = origDuration - firstDuration;

    // Update first half
    ref.read(projectProvider.notifier).updateAsset(
      asset.id,
      (a) => a.copyWith(durationSec: firstDuration),
    );

    // Add second half
    ref.read(projectProvider.notifier).addAsset(TimelineAsset(
      id: 'split_${DateTime.now().millisecondsSinceEpoch}',
      track: asset.track,
      label: '${asset.label} (2)',
      filePath: asset.filePath,
      url: asset.url,
      thumbnailUrl: asset.thumbnailUrl,
      startSec: playheadSec,
      durationSec: secondDuration,
      speed: asset.speed,
      visible: asset.visible,
      locked: asset.locked,
      volume: asset.volume,
      metadata: asset.metadata,
    ));
  }

  /// Duplicate the selected asset.
  void _duplicateSelected() {
    if (_selectedAssetId == null) return;
    final project = ref.read(projectProvider);
    final asset = project.assets.where((a) => a.id == _selectedAssetId).firstOrNull;
    if (asset == null) return;

    final dur = asset.durationSec > 0 ? asset.durationSec : 10.0;
    ref.read(projectProvider.notifier).addAsset(TimelineAsset(
      id: 'dup_${DateTime.now().millisecondsSinceEpoch}',
      track: asset.track,
      label: '${asset.label} (copy)',
      filePath: asset.filePath,
      url: asset.url,
      thumbnailUrl: asset.thumbnailUrl,
      startSec: asset.startSec + dur,
      durationSec: dur,
      speed: asset.speed,
      visible: asset.visible,
      locked: asset.locked,
      volume: asset.volume,
      metadata: asset.metadata,
    ));
  }

  /// Delete the selected asset.
  void _deleteSelected() {
    if (_selectedAssetId == null) return;
    ref.read(projectProvider.notifier).removeAsset(_selectedAssetId!);
    setState(() {
      _selectedAssetId = null;
      if (_rightPanel == _RightPanel.assetProperties) {
        _rightPanel = _RightPanel.layers;
      }
    });
  }

  @override
  void dispose() {
    _horizontalScroll.dispose();
    _stockSearchController.dispose();
    _previewPlayingNotifier.dispose();
    _previewPositionNotifier.dispose();
    _previewDurationNotifier.dispose();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _previewPlayer?.dispose();
    super.dispose();
  }

  void _initPreviewPlayer(String path) {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    if (_previewPlayer != null) {
      _previewPlayer!.dispose();
    }
    _previewPlayer = Player();
    _previewController = VideoController(_previewPlayer!);
    final media = Media(path);
    _previewPlayer!.open(media);
    _previewPlayer!.setPlaylistMode(PlaylistMode.loop);
    // Enable audio volume
    _previewPlayer!.setVolume(100);
    _previewPlayingNotifier.value = true;
    // Use ValueNotifiers — these update ONLY the widgets listening to them,
    // NOT the entire widget tree.  This prevents scroll-fighting.
    _playingSub = _previewPlayer!.stream.playing.listen((playing) {
      if (mounted) _previewPlayingNotifier.value = playing;
    });
    _positionSub = _previewPlayer!.stream.position.listen((pos) {
      if (mounted) _previewPositionNotifier.value = pos;
    });
    _durationSub = _previewPlayer!.stream.duration.listen((dur) {
      if (mounted) _previewDurationNotifier.value = dur;
    });
    // Trigger one rebuild so the VideoController widget appears.
    if (mounted) setState(() {});
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

      // Collect actual video/broll URLs from timeline assets sorted by position
      final videoClips = project.assets
          .where((a) =>
              (a.track == TimelineTrack.video || a.track == TimelineTrack.broll) &&
              a.visible &&
              (a.url != null || a.filePath != null))
          .toList()
        ..sort((a, b) => a.startSec.compareTo(b.startSec));
      final bgUrls = videoClips
          .where((a) => a.url != null)
          .map((a) => a.url!)
          .toList();

      final payload = <String, dynamic>{
        'text': project.scriptText,
        'title': project.scriptTitle ?? 'Untitled',
        'api_key': openaiKey,
        'voice': project.selectedVoice.name,
        'output_dir': shortsDir.path,
        'visual_keywords': visualKeywords,
        if (bgUrls.isNotEmpty) 'background_video_urls': bgUrls,
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

        if (!mounted) return;

        // Show a persistent banner instead of SnackBar for better UX
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E1E2E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            icon: const Icon(Icons.check_circle, color: Color(0xFF00C853), size: 48),
            title: const Text('Render Complete!'),
            content: Text(
              '${duration.toStringAsFixed(0)}s video saved successfully.\n$outputPath',
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Close'),
              ),
              if (outputPath.isNotEmpty)
                FilledButton.icon(
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Open Folder'),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _openOutputFolder(outputPath);
                  },
                ),
            ],
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

  void _openOutputFolder(String outputPath) {
    try {
      final dir = outputPath.contains(Platform.pathSeparator)
          ? outputPath.substring(0, outputPath.lastIndexOf(Platform.pathSeparator))
          : outputPath;
      if (Platform.isWindows) {
        Process.run('explorer.exe', [dir]);
      } else if (Platform.isMacOS) {
        Process.run('open', [dir]);
      } else {
        Process.run('xdg-open', [dir]);
      }
    } catch (_) {
      // Silently ignore if folder can't be opened
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

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        // Delete key
        if (key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace) {
          _deleteSelected();
          return KeyEventResult.handled;
        }
        // S = split at playhead
        if (key == LogicalKeyboardKey.keyS && !HardwareKeyboard.instance.isControlPressed) {
          _splitAtPlayhead();
          return KeyEventResult.handled;
        }
        // V = select tool
        if (key == LogicalKeyboardKey.keyV) {
          setState(() => _activeTool = _EditorTool.select);
          return KeyEventResult.handled;
        }
        // C = razor tool
        if (key == LogicalKeyboardKey.keyC && !HardwareKeyboard.instance.isControlPressed) {
          setState(() => _activeTool = _EditorTool.razor);
          return KeyEventResult.handled;
        }
        // H = hand tool
        if (key == LogicalKeyboardKey.keyH) {
          setState(() => _activeTool = _EditorTool.hand);
          return KeyEventResult.handled;
        }
        // Ctrl+D = duplicate
        if (key == LogicalKeyboardKey.keyD && HardwareKeyboard.instance.isControlPressed) {
          _duplicateSelected();
          return KeyEventResult.handled;
        }
        // Space = play/pause
        if (key == LogicalKeyboardKey.space) {
          _previewPlayer?.playOrPause();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Row(
        children: [
          // Main timeline area
        Expanded(
          child: Column(
            children: [
              // Top bar: video preview + controls + script
              Expanded(
                child: Container(
                  color: const Color(0xFF0A0A14),
                  child: _importedVideoPath == null && project.scriptText == null
                      ? _buildEmptyPreview()
                      : _buildProjectView(project),
                ),
              ),
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
              // Resizable drag handle for timeline
              GestureDetector(
                onVerticalDragUpdate: (details) {
                  setState(() {
                    _timelinePanelHeight = (_timelinePanelHeight - details.delta.dy)
                        .clamp(_minTimelineHeight, _maxTimelineHeight);
                  });
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeRow,
                  child: Container(
                    height: 8,
                    color: const Color(0xFF1A1A2A),
                    child: Center(
                      child: Container(
                        width: 40,
                        height: 3,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Transport controls bar (play/pause/etc) — now above the timeline tracks
              _buildTransportBar(project),
              const Divider(height: 1),
              // Editor toolbar (tools, split, delete, etc.)
              _buildEditorToolbar(project),
              const Divider(height: 1),
              // Timeline tracks — resizable
              SizedBox(
                height: _timelinePanelHeight,
                child: _buildTimelineTracks(project),
              ),
            ],
          ),
        ),
        // Right side panel (stock footage / text editor / asset properties)
        if (_rightPanel != _RightPanel.none) ...[
          Container(width: 1, color: Colors.white.withOpacity(0.06)),
          SizedBox(
            width: _rightPanel == _RightPanel.aiCreate ? 400 : 320,
            child: _rightPanel == _RightPanel.stockFootage
                ? _buildStockFootagePanel()
                : _rightPanel == _RightPanel.textEditor
                    ? _buildTextEditorPanel(project)
                    : _rightPanel == _RightPanel.voicePicker
                        ? _buildVoicePanel(project)
                        : _rightPanel == _RightPanel.assetProperties
                            ? _buildAssetPropertiesPanel(project)
                            : _rightPanel == _RightPanel.aiCreate
                                ? _buildAiCreatePanel(project)
                                : _buildLayersPanel(project),
          ),
        ],
      ],
    ),
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
          // Left: 9:16 Phone Frame Preview with draggable text
          _buildPhonePreview(project),
          const SizedBox(width: 20),
          // Right: controls + script — wrapped in a non-auto-scrolling column
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
                // Quick-action chips — use a non-scrolling Wrap
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
                    // Layers panel button
                    _buildActionChip(
                      icon: Icons.layers,
                      label: 'Layers',
                      color: _rightPanel == _RightPanel.layers
                          ? const Color(0xFF00C853)
                          : const Color(0xFF2D6482),
                      busy: false,
                      onTap: () => setState(() {
                        _rightPanel = _rightPanel == _RightPanel.layers
                            ? _RightPanel.none
                            : _RightPanel.layers;
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
                    // AI Create button — opens Fact Shorts as an add-in
                    _buildActionChip(
                      icon: Icons.auto_awesome,
                      label: 'AI Create',
                      color: _rightPanel == _RightPanel.aiCreate
                          ? const Color(0xFF00C853)
                          : const Color(0xFF6C5CE7),
                      busy: false,
                      onTap: () => setState(() {
                        _rightPanel = _rightPanel == _RightPanel.aiCreate
                            ? _RightPanel.none
                            : _RightPanel.aiCreate;
                      }),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Render button
                if (project.scriptText != null) ...[
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
                  const SizedBox(height: 12),
                ],
                // Script preview — fixed in place, no auto-scroll
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
                        // NeverScrollable by default — only scrolls on user gesture
                        physics: const ClampingScrollPhysics(),
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
                      physics: const ClampingScrollPhysics(),
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
                                  formatTimeMMSS(start),
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
                      physics: const ClampingScrollPhysics(),
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
  Widget _buildPhonePreview(ProjectState project) {
    final style = project.captionStyle;
    final titleText = project.scriptTitle ?? '';
    final scriptText = project.scriptText ?? '';
    final hasTitle = titleText.isNotEmpty;
    final hasScript = scriptText.isNotEmpty;

    // Check if there's a video-track asset with a URL
    final videoAssets =
        project.assets.where((a) => a.track == TimelineTrack.video).toList();
    final bgUrl = videoAssets.isNotEmpty
        ? (videoAssets.first.url ?? videoAssets.first.thumbnailUrl ?? '')
        : '';

    // Auto-load background from URL if no local video is loaded
    // Schedule for after build — never call _initPreviewPlayer during build.
    if (bgUrl.isNotEmpty && _previewController == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _previewController == null) {
          _initPreviewPlayer(bgUrl);
        }
      });
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
                        // Title text (top area)
                        if (hasTitle)
                          Positioned(
                            top: project.titleStyle.positionY * frameH,
                            left: 8,
                            right: 8,
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _selectedTextElement = _SelectedTextElement.title;
                                  _rightPanel = _RightPanel.textEditor;
                                });
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                decoration: BoxDecoration(
                                  border: _selectedTextElement == _SelectedTextElement.title
                                      ? Border.all(color: const Color(0xFF6C5CE7), width: 1.5)
                                      : null,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  titleText,
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: project.titleStyle.fontFamily,
                                    fontSize: (project.titleStyle.fontSize * 0.45).clamp(10, 20),
                                    fontWeight: FontWeight.w800,
                                    color: Color(project.titleStyle.colorHex),
                                    shadows: project.titleStyle.hasBorder
                                        ? const [
                                            Shadow(color: Colors.black, blurRadius: 6),
                                            Shadow(color: Colors.black, blurRadius: 12),
                                          ]
                                        : null,
                                  ),
                                ),
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
                              onTap: () {
                                setState(() {
                                  _selectedTextElement = _SelectedTextElement.body;
                                  _rightPanel = _RightPanel.textEditor;
                                });
                              },
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
                                    color: _selectedTextElement == _SelectedTextElement.body
                                        ? const Color(0xFF6C5CE7)
                                        : const Color(0xFF6C5CE7).withOpacity(0.3),
                                    width: _selectedTextElement == _SelectedTextElement.body ? 1.5 : 1,
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
                        // Position presets
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
                        // Volume indicator in the preview
                        if (_previewPlayer != null)
                          Positioned(
                            right: 4,
                            bottom: 4,
                            child: GestureDetector(
                              onTap: () {
                                final current = _previewPlayer!.state.volume;
                                _previewPlayer!.setVolume(current > 0 ? 0 : 100);
                              },
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Icon(
                                  _previewPlayer!.state.volume > 0
                                      ? Icons.volume_up
                                      : Icons.volume_off,
                                  size: 14,
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

  /// Transport bar with play/pause, skip, scrub, and time display
  /// — now positioned directly above the timeline tracks.
  /// Uses ValueListenableBuilder so only this bar rebuilds on playback
  /// updates, leaving all scroll views untouched.
  Widget _buildTransportBar(ProjectState project) {
    return ValueListenableBuilder<Duration>(
      valueListenable: _previewPositionNotifier,
      builder: (context, previewPosition, _) {
        return ValueListenableBuilder<Duration>(
          valueListenable: _previewDurationNotifier,
          builder: (context, previewDuration, _) {
            return ValueListenableBuilder<bool>(
              valueListenable: _previewPlayingNotifier,
              builder: (context, previewPlaying, _) {
                final posMs = previewPosition.inMilliseconds;
                final durMs = previewDuration.inMilliseconds;
                final posStr = _formatDuration(previewPosition);
                final durStr = _formatDuration(previewDuration);

                return Container(
                  height: 48,
                  color: const Color(0xFF141420),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      // Skip to start
                      IconButton(
                        icon: const Icon(Icons.skip_previous, size: 20),
                        onPressed: () {
                          _previewPlayer?.seek(Duration.zero);
                          setState(() => _playheadPosition = 0);
                        },
                        tooltip: 'Go to start',
                      ),
                      // Rewind 5s
                      IconButton(
                        icon: const Icon(Icons.replay_5, size: 20),
                        onPressed: () {
                          if (_previewPlayer != null) {
                            final newPos = previewPosition - const Duration(seconds: 5);
                            _previewPlayer!.seek(newPos < Duration.zero ? Duration.zero : newPos);
                          }
                        },
                        tooltip: 'Back 5s',
                      ),
                      // Play / Pause
                      IconButton(
                        icon: Icon(
                          previewPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                          size: 32,
                          color: const Color(0xFF6C5CE7),
                        ),
                        onPressed: () => _previewPlayer?.playOrPause(),
                        tooltip: previewPlaying ? 'Pause' : 'Play',
                      ),
                      // Forward 5s
                      IconButton(
                        icon: const Icon(Icons.forward_5, size: 20),
                        onPressed: () {
                          if (_previewPlayer != null) {
                            final newPos = previewPosition + const Duration(seconds: 5);
                            _previewPlayer!.seek(newPos > previewDuration ? previewDuration : newPos);
                          }
                        },
                        tooltip: 'Forward 5s',
                      ),
                      // Skip to end
                      IconButton(
                        icon: const Icon(Icons.skip_next, size: 20),
                        onPressed: () {
                          if (_previewPlayer != null && previewDuration > Duration.zero) {
                            _previewPlayer!.seek(previewDuration);
                          }
                        },
                        tooltip: 'Go to end',
                      ),
                      const SizedBox(width: 8),
                      // Time display
                      Text(
                        '$posStr / $durStr',
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: Colors.white.withOpacity(0.6),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Scrubber / seek bar
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 4,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                            activeTrackColor: const Color(0xFF6C5CE7),
                            inactiveTrackColor: Colors.white12,
                            thumbColor: const Color(0xFF6C5CE7),
                          ),
                          child: Slider(
                            value: durMs > 0 ? (posMs / durMs).clamp(0.0, 1.0) : 0.0,
                            onChanged: (v) {
                              if (_previewPlayer != null && durMs > 0) {
                                _previewPlayer!.seek(Duration(milliseconds: (v * durMs).toInt()));
                              }
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Zoom control
                      const Text('Zoom:', style: TextStyle(fontSize: 11, color: Colors.white38)),
                      SizedBox(
                        width: 100,
                        child: Slider(
                          value: _zoomLevel,
                          min: 0.25,
                          max: 4.0,
                          onChanged: (v) => setState(() => _zoomLevel = v),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        label: const Text('Snap', style: TextStyle(fontSize: 10)),
                        selected: true,
                        onSelected: (_) {},
                        visualDensity: VisualDensity.compact,
                      ),
                      const SizedBox(width: 4),
                      FilterChip(
                        label: Text(
                          _proxyPath != null ? 'Proxy ON' : 'Proxy',
                          style: const TextStyle(fontSize: 10),
                        ),
                        selected: _proxyPath != null,
                        onSelected: (_) {},
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _buildTimelineTracks(ProjectState project) {
    final brollAssets =
        project.assets.where((a) => a.track == TimelineTrack.broll).toList();
    final totalWidth = 2000.0 * _zoomLevel;

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
                  width: 110,
                  child: Column(
                    children: [
                      // Time ruler label
                      Container(
                        height: 24,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: const BoxDecoration(
                          color: Color(0xFF1A1A28),
                          border: Border(bottom: BorderSide(color: Colors.white10)),
                        ),
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Time',
                          style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.3)),
                        ),
                      ),
                      _buildTrackLabel('Video', Icons.videocam, const Color(0xFF2D5AA0)),
                      _buildTrackLabel('B-Roll', Icons.movie_filter, const Color(0xFF5A2D82)),
                      _buildTrackLabel('Audio', Icons.audiotrack, const Color(0xFF2D824A)),
                      _buildTrackLabel('Captions', Icons.subtitles, const Color(0xFF82782D)),
                      _buildTrackLabel('Crops', Icons.crop, const Color(0xFF822D5A)),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                // Scrollable track area
                Expanded(
                  child: SingleChildScrollView(
                    controller: _horizontalScroll,
                    scrollDirection: Axis.horizontal,
                    physics: const ClampingScrollPhysics(),
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTapDown: (details) {
                        // Click on timeline background moves the playhead
                        final secPos = details.localPosition.dx / _pixelsPerSec;
                        setState(() {
                          _playheadPosition = details.localPosition.dx / _zoomLevel;
                        });
                        if (_previewPlayer != null) {
                          _previewPlayer!.seek(Duration(milliseconds: (secPos * 1000).toInt()));
                        }
                      },
                      child: SizedBox(
                        width: totalWidth,
                        child: Stack(
                          children: [
                            Column(
                              children: [
                                // Time ruler
                                _buildTimeRuler(totalWidth),
                                _buildTrackRow(
                                  const Color(0xFF2D5AA0),
                                  track: TimelineTrack.video,
                                  assets: project.assets.where((a) => a.track == TimelineTrack.video).toList(),
                                ),
                                _buildTrackRow(
                                  const Color(0xFF5A2D82),
                                  track: TimelineTrack.broll,
                                  assets: brollAssets,
                                ),
                                _buildTrackRow(
                                  const Color(0xFF2D824A),
                                  track: TimelineTrack.audio,
                                  assets: project.assets.where((a) => a.track == TimelineTrack.audio).toList(),
                                  extraLabel: _ttsAudioPath != null && project.assets.where((a) => a.track == TimelineTrack.audio).isEmpty
                                      ? 'Voiceover (${project.selectedVoice.label})'
                                      : null,
                                ),
                                _buildTrackRow(
                                  const Color(0xFF82782D),
                                  track: TimelineTrack.captions,
                                  assets: project.assets.where((a) => a.track == TimelineTrack.captions).toList(),
                                  extraLabel: _transcriptSegments.isNotEmpty
                                      ? '${_transcriptSegments.length} captions'
                                      : project.scriptText != null
                                          ? 'Script captions'
                                          : null,
                                ),
                                _buildTrackRow(
                                  const Color(0xFF822D5A),
                                  track: TimelineTrack.crops,
                                  assets: project.assets.where((a) => a.track == TimelineTrack.crops).toList(),
                                ),
                              ],
                            ),
                            // Playhead
                            Positioned(
                              left: _playheadPosition * _zoomLevel,
                              top: 0,
                              bottom: 0,
                              child: IgnorePointer(
                                child: Column(
                                  children: [
                                    // Playhead top triangle
                                    CustomPaint(
                                      size: const Size(12, 8),
                                      painter: _PlayheadTrianglePainter(),
                                    ),
                                    Expanded(
                                      child: Container(
                                        width: 2,
                                        color: Colors.redAccent,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
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

  /// Time ruler showing seconds / minutes marks
  Widget _buildTimeRuler(double totalWidth) {
    return Container(
      height: 24,
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A28),
        border: Border(bottom: BorderSide(color: Colors.white10)),
      ),
      child: CustomPaint(
        size: Size(totalWidth, 24),
        painter: _TimeRulerPainter(pixelsPerSec: _pixelsPerSec),
      ),
    );
  }

  // ─── Layers Panel — shows all assets with full control ───

  Widget _buildLayersPanel(ProjectState project) {
    final allAssets = project.assets;

    return Container(
      color: const Color(0xFF1A1A2A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Icon(Icons.layers, size: 18, color: Color(0xFF2D6482)),
                const SizedBox(width: 8),
                const Text('Layers / Assets',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
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
          // Asset list
          Expanded(
            child: allAssets.isEmpty
                ? Center(
                    child: Text(
                      'No assets on the timeline.\nImport media or use Fact Shorts.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.3),
                      ),
                    ),
                  )
                : ReorderableListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: allAssets.length,
                    onReorder: (oldIndex, newIndex) {
                      if (newIndex > oldIndex) newIndex--;
                      ref.read(projectProvider.notifier).reorderAsset(
                            allAssets[oldIndex].id,
                            newIndex,
                          );
                    },
                    itemBuilder: (context, index) {
                      final asset = allAssets[index];
                      final isSelected = asset.id == _selectedAssetId;
                      final trackColor = _trackColor(asset.track);
                      final trackIcon = _trackIcon(asset.track);

                      return Card(
                        key: ValueKey(asset.id),
                        color: isSelected
                            ? const Color(0xFF6C5CE7).withOpacity(0.15)
                            : const Color(0xFF1E1E2E),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: isSelected
                              ? const BorderSide(color: Color(0xFF6C5CE7), width: 1)
                              : BorderSide.none,
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () {
                            setState(() {
                              _selectedAssetId = isSelected ? null : asset.id;
                              if (_selectedAssetId != null) {
                                _rightPanel = _RightPanel.assetProperties;
                              }
                            });
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Row(
                              children: [
                                // Drag handle
                                const Icon(Icons.drag_handle, size: 16, color: Colors.white24),
                                const SizedBox(width: 4),
                                // Track color indicator
                                Container(
                                  width: 4,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: trackColor,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // Icon
                                Icon(trackIcon, size: 16, color: trackColor),
                                const SizedBox(width: 8),
                                // Label + track name
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        asset.label,
                                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        '${asset.track.name.toUpperCase()} | ${asset.speed}x',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: Colors.white.withOpacity(0.4),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                // Visibility toggle
                                IconButton(
                                  icon: Icon(
                                    asset.visible ? Icons.visibility : Icons.visibility_off,
                                    size: 16,
                                    color: asset.visible ? Colors.white54 : Colors.white24,
                                  ),
                                  onPressed: () {
                                    ref.read(projectProvider.notifier).updateAsset(
                                      asset.id,
                                      (a) => a.copyWith(visible: !a.visible),
                                    );
                                  },
                                  visualDensity: VisualDensity.compact,
                                  tooltip: asset.visible ? 'Hide' : 'Show',
                                ),
                                // Lock toggle
                                IconButton(
                                  icon: Icon(
                                    asset.locked ? Icons.lock : Icons.lock_open,
                                    size: 14,
                                    color: asset.locked ? Colors.orangeAccent : Colors.white24,
                                  ),
                                  onPressed: () {
                                    ref.read(projectProvider.notifier).updateAsset(
                                      asset.id,
                                      (a) => a.copyWith(locked: !a.locked),
                                    );
                                  },
                                  visualDensity: VisualDensity.compact,
                                  tooltip: asset.locked ? 'Unlock' : 'Lock',
                                ),
                                // Delete
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                                  onPressed: () {
                                    ref.read(projectProvider.notifier).removeAsset(asset.id);
                                    if (_selectedAssetId == asset.id) {
                                      setState(() => _selectedAssetId = null);
                                    }
                                  },
                                  visualDensity: VisualDensity.compact,
                                  tooltip: 'Remove',
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ─── Asset Properties Panel — per-asset controls (speed, volume, position) ───

  Widget _buildAssetPropertiesPanel(ProjectState project) {
    final asset = _selectedAssetId != null
        ? project.assets.where((a) => a.id == _selectedAssetId).firstOrNull
        : null;

    if (asset == null) {
      // Fallback to layers panel
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() => _rightPanel = _RightPanel.layers);
      });
      return const SizedBox.shrink();
    }

    final trackColor = _trackColor(asset.track);

    return Container(
      color: const Color(0xFF1A1A2A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(_trackIcon(asset.track), size: 18, color: trackColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    asset.label,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_back, size: 18),
                  onPressed: () => setState(() => _rightPanel = _RightPanel.layers),
                  tooltip: 'Back to Layers',
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => _rightPanel = _RightPanel.none),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Track info
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: trackColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: trackColor.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(color: trackColor, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Track: ${asset.track.name.toUpperCase()}',
                          style: TextStyle(fontSize: 12, color: trackColor, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Label editor
                  const Text('Label', style: TextStyle(fontSize: 11, color: Colors.white54)),
                  const SizedBox(height: 4),
                  TextFormField(
                    initialValue: asset.label,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    onFieldSubmitted: (v) {
                      ref.read(projectProvider.notifier).updateAsset(
                        asset.id,
                        (a) => a.copyWith(label: v),
                      );
                    },
                  ),
                  const SizedBox(height: 16),

                  // Speed control
                  Row(
                    children: [
                      const Text('Speed', style: TextStyle(fontSize: 11, color: Colors.white54)),
                      const Spacer(),
                      Text(
                        '${asset.speed.toStringAsFixed(2)}x',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6C5CE7)),
                      ),
                    ],
                  ),
                  Slider(
                    value: asset.speed,
                    min: 0.25,
                    max: 4.0,
                    divisions: 15,
                    label: '${asset.speed.toStringAsFixed(2)}x',
                    onChanged: (v) {
                      ref.read(projectProvider.notifier).updateAsset(
                        asset.id,
                        (a) => a.copyWith(speed: v),
                      );
                    },
                  ),
                  // Speed presets
                  Wrap(
                    spacing: 4,
                    children: [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 4.0].map((s) {
                      final isActive = (asset.speed - s).abs() < 0.01;
                      return ActionChip(
                        label: Text('${s}x', style: TextStyle(fontSize: 10, color: isActive ? Colors.white : Colors.white54)),
                        backgroundColor: isActive ? const Color(0xFF6C5CE7) : Colors.white.withOpacity(0.05),
                        side: BorderSide.none,
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          ref.read(projectProvider.notifier).updateAsset(
                            asset.id,
                            (a) => a.copyWith(speed: s),
                          );
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),

                  // Volume control (for video & audio tracks)
                  if (asset.track == TimelineTrack.video ||
                      asset.track == TimelineTrack.audio ||
                      asset.track == TimelineTrack.broll) ...[
                    Row(
                      children: [
                        const Text('Volume', style: TextStyle(fontSize: 11, color: Colors.white54)),
                        const Spacer(),
                        Text(
                          '${(asset.volume * 100).toInt()}%',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF2D824A)),
                        ),
                      ],
                    ),
                    Slider(
                      value: asset.volume,
                      min: 0.0,
                      max: 1.0,
                      divisions: 20,
                      label: '${(asset.volume * 100).toInt()}%',
                      activeColor: const Color(0xFF2D824A),
                      onChanged: (v) {
                        ref.read(projectProvider.notifier).updateAsset(
                          asset.id,
                          (a) => a.copyWith(volume: v),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Start time
                  Row(
                    children: [
                      const Text('Start', style: TextStyle(fontSize: 11, color: Colors.white54)),
                      const Spacer(),
                      Text(
                        '${asset.startSec.toStringAsFixed(1)}s',
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                    ],
                  ),
                  Slider(
                    value: asset.startSec,
                    min: 0,
                    max: 120,
                    onChanged: (v) {
                      ref.read(projectProvider.notifier).updateAsset(
                        asset.id,
                        (a) => a.copyWith(startSec: v),
                      );
                    },
                  ),
                  const SizedBox(height: 8),

                  // Duration
                  Row(
                    children: [
                      const Text('Duration', style: TextStyle(fontSize: 11, color: Colors.white54)),
                      const Spacer(),
                      Text(
                        '${asset.durationSec.toStringAsFixed(1)}s',
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                    ],
                  ),
                  Slider(
                    value: asset.durationSec,
                    min: 0,
                    max: 300,
                    onChanged: (v) {
                      ref.read(projectProvider.notifier).updateAsset(
                        asset.id,
                        (a) => a.copyWith(durationSec: v),
                      );
                    },
                  ),
                  const SizedBox(height: 16),

                  // Visibility & Lock
                  Row(
                    children: [
                      Expanded(
                        child: SwitchListTile(
                          title: const Text('Visible', style: TextStyle(fontSize: 12)),
                          value: asset.visible,
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          onChanged: (v) {
                            ref.read(projectProvider.notifier).updateAsset(
                              asset.id,
                              (a) => a.copyWith(visible: v),
                            );
                          },
                        ),
                      ),
                      Expanded(
                        child: SwitchListTile(
                          title: const Text('Locked', style: TextStyle(fontSize: 12)),
                          value: asset.locked,
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          onChanged: (v) {
                            ref.read(projectProvider.notifier).updateAsset(
                              asset.id,
                              (a) => a.copyWith(locked: v),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // File info
                  if (asset.filePath != null) ...[
                    const Text('File', style: TextStyle(fontSize: 11, color: Colors.white54)),
                    const SizedBox(height: 4),
                    Text(
                      asset.filePath!,
                      style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.4)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (asset.url != null) ...[
                    const SizedBox(height: 8),
                    const Text('URL', style: TextStyle(fontSize: 11, color: Colors.white54)),
                    const SizedBox(height: 4),
                    Text(
                      asset.url!,
                      style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.4)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 16),

                  // Delete button
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        ref.read(projectProvider.notifier).removeAsset(asset.id);
                        setState(() {
                          _selectedAssetId = null;
                          _rightPanel = _RightPanel.layers;
                        });
                      },
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: const Text('Remove Asset'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        side: const BorderSide(color: Colors.redAccent),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _trackColor(TimelineTrack track) {
    return switch (track) {
      TimelineTrack.video => const Color(0xFF2D5AA0),
      TimelineTrack.broll => const Color(0xFF5A2D82),
      TimelineTrack.audio => const Color(0xFF2D824A),
      TimelineTrack.captions => const Color(0xFF82782D),
      TimelineTrack.crops => const Color(0xFF822D5A),
    };
  }

  IconData _trackIcon(TimelineTrack track) {
    return switch (track) {
      TimelineTrack.video => Icons.videocam,
      TimelineTrack.broll => Icons.movie_filter,
      TimelineTrack.audio => Icons.audiotrack,
      TimelineTrack.captions => Icons.subtitles,
      TimelineTrack.crops => Icons.crop,
    };
  }

  // ─── Right panels (stock, text, voice) ───

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
                    physics: const ClampingScrollPhysics(),
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
    // Default to body if nothing is selected
    if (_selectedTextElement == _SelectedTextElement.none) {
      _selectedTextElement = _SelectedTextElement.body;
    }

    final isTitle = _selectedTextElement == _SelectedTextElement.title;
    final style = isTitle ? project.titleStyle : project.captionStyle;

    void updateStyle(CaptionStyle newStyle) {
      if (isTitle) {
        ref.read(projectProvider.notifier).setTitleStyle(newStyle);
      } else {
        ref.read(projectProvider.notifier).setCaptionStyle(newStyle);
      }
    }

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
                      setState(() {
                        _rightPanel = _RightPanel.none;
                        _selectedTextElement = _SelectedTextElement.none;
                      }),
                ),
              ],
            ),
          ),
          // Title / Body toggle tabs
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _selectedTextElement = _SelectedTextElement.title),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: isTitle ? const Color(0xFF6C5CE7).withOpacity(0.3) : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: isTitle ? Border.all(color: const Color(0xFF6C5CE7), width: 1) : null,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.title, size: 14, color: isTitle ? const Color(0xFF6C5CE7) : Colors.white38),
                          const SizedBox(width: 4),
                          Text(
                            'Title',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isTitle ? Colors.white : Colors.white38,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _selectedTextElement = _SelectedTextElement.body),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: !isTitle ? const Color(0xFF6C5CE7).withOpacity(0.3) : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: !isTitle ? Border.all(color: const Color(0xFF6C5CE7), width: 1) : null,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.notes, size: 14, color: !isTitle ? const Color(0xFF6C5CE7) : Colors.white38),
                          const SizedBox(width: 4),
                          Text(
                            'Body',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: !isTitle ? Colors.white : Colors.white38,
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
          const SizedBox(height: 8),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
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
                        updateStyle(style.copyWith(fontFamily: v));
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
                      updateStyle(style.copyWith(fontSize: v));
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
                        updateStyle(style.copyWith(colorHex: c));
                      }),
                      _colorCircle(0xFFFFD700, style.colorHex, (c) {
                        updateStyle(style.copyWith(colorHex: c));
                      }),
                      _colorCircle(0xFF6C5CE7, style.colorHex, (c) {
                        updateStyle(style.copyWith(colorHex: c));
                      }),
                      _colorCircle(0xFF00C853, style.colorHex, (c) {
                        updateStyle(style.copyWith(colorHex: c));
                      }),
                      _colorCircle(0xFFFF5252, style.colorHex, (c) {
                        updateStyle(style.copyWith(colorHex: c));
                      }),
                      _colorCircle(0xFF40C4FF, style.colorHex, (c) {
                        updateStyle(style.copyWith(colorHex: c));
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
                      updateStyle(style.copyWith(hasBorder: v));
                    },
                  ),
                  if (!isTitle) ...[
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
              physics: const ClampingScrollPhysics(),
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

  // ─── AI Create Panel — inline Fact Shorts add-in ───

  Widget _buildAiCreatePanel(ProjectState project) {
    return Container(
      color: const Color(0xFF1A1A2A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome,
                    size: 18, color: Color(0xFF6C5CE7)),
                const SizedBox(width: 8),
                const Text('AI Create',
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
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Generate AI content directly into your timeline.',
                      style: TextStyle(fontSize: 12, color: Colors.white54)),
                  const SizedBox(height: 16),
                  // Open full Fact Shorts creator
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () {
                        // Navigate to Fact Shorts page
                        final tabNotifier = ref.read(selectedTabProvider.notifier);
                        // Find the Fact Shorts page — it's no longer in main nav,
                        // so open as a dialog
                        _openFactShortsDialog();
                      },
                      icon: const Icon(Icons.auto_awesome, size: 18),
                      label: const Text('Open AI Script Generator'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 16),
                  // Quick actions
                  const Text('Quick Actions',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white70)),
                  const SizedBox(height: 8),
                  _buildQuickAction(
                    icon: Icons.record_voice_over,
                    label: 'Generate Voiceover',
                    subtitle: 'Create TTS audio from script',
                    onTap: project.scriptText != null ? () {
                      // Use existing _renderVideo or generate TTS
                    } : null,
                  ),
                  _buildQuickAction(
                    icon: Icons.movie_filter,
                    label: 'Find Stock Footage',
                    subtitle: 'Search Pexels & Pixabay',
                    onTap: () => setState(() {
                      _rightPanel = _RightPanel.stockFootage;
                    }),
                  ),
                  _buildQuickAction(
                    icon: Icons.subtitles,
                    label: 'Auto-Caption',
                    subtitle: 'Transcribe audio to captions',
                    onTap: _importedVideoPath != null && !_isBusy
                        ? _transcribeVideo
                        : null,
                  ),
                  _buildQuickAction(
                    icon: Icons.text_fields,
                    label: 'Edit Text Overlays',
                    subtitle: 'Title and body text styling',
                    onTap: project.scriptText != null
                        ? () => setState(() {
                              _rightPanel = _RightPanel.textEditor;
                            })
                        : null,
                  ),
                  _buildQuickAction(
                    icon: Icons.movie_creation,
                    label: 'Render Video',
                    subtitle: 'Export final 9:16 short',
                    onTap: project.scriptText != null && !_isBusy
                        ? _renderVideo
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickAction({
    required IconData icon,
    required String label,
    required String subtitle,
    VoidCallback? onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(onTap != null ? 0.04 : 0.02),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Colors.white.withOpacity(onTap != null ? 0.08 : 0.04),
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20,
                  color: onTap != null
                      ? const Color(0xFF6C5CE7)
                      : Colors.white24),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: onTap != null ? Colors.white70 : Colors.white30,
                        )),
                    Text(subtitle,
                        style: TextStyle(
                          fontSize: 10,
                          color: onTap != null ? Colors.white38 : Colors.white.withOpacity(0.2),
                        )),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_ios, size: 12,
                  color: onTap != null ? Colors.white24 : Colors.white10),
            ],
          ),
        ),
      ),
    );
  }

  void _openFactShortsDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF1A1A2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: MediaQuery.of(ctx).size.width * 0.85,
          height: MediaQuery.of(ctx).size.height * 0.85,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: const FactShortsPage(),
          ),
        ),
      ),
    );
  }

  // ─── Editor Toolbar ───

  Widget _buildEditorToolbar(ProjectState project) {
    final hasSelection = _selectedAssetId != null;
    return Container(
      height: 36,
      color: const Color(0xFF1A1A28),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          // Tool selection
          _toolButton(Icons.near_me, 'Select (V)', _EditorTool.select),
          _toolButton(Icons.content_cut, 'Razor (C)', _EditorTool.razor),
          _toolButton(Icons.pan_tool_alt, 'Hand (H)', _EditorTool.hand),
          Container(width: 1, height: 20, color: Colors.white10,
              margin: const EdgeInsets.symmetric(horizontal: 6)),
          // Edit actions
          _actionButton(Icons.splitscreen, 'Split at Playhead (S)',
              hasSelection ? _splitAtPlayhead : null),
          _actionButton(Icons.copy, 'Duplicate (Ctrl+D)',
              hasSelection ? _duplicateSelected : null),
          _actionButton(Icons.delete_outline, 'Delete (Del)',
              hasSelection ? _deleteSelected : null),
          Container(width: 1, height: 20, color: Colors.white10,
              margin: const EdgeInsets.symmetric(horizontal: 6)),
          // Snap toggle
          GestureDetector(
            onTap: () => setState(() => _snapEnabled = !_snapEnabled),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _snapEnabled
                    ? const Color(0xFF6C5CE7).withOpacity(0.2)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: _snapEnabled
                      ? const Color(0xFF6C5CE7).withOpacity(0.5)
                      : Colors.white12,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.grid_on, size: 12,
                      color: _snapEnabled
                          ? const Color(0xFF6C5CE7)
                          : Colors.white38),
                  const SizedBox(width: 4),
                  Text('Snap',
                      style: TextStyle(
                        fontSize: 10,
                        color: _snapEnabled
                            ? const Color(0xFF6C5CE7)
                            : Colors.white38,
                      )),
                ],
              ),
            ),
          ),
          const Spacer(),
          // Selection info
          if (hasSelection)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Builder(builder: (context) {
                final asset = project.assets
                    .where((a) => a.id == _selectedAssetId)
                    .firstOrNull;
                if (asset == null) return const SizedBox.shrink();
                return Text(
                  '${asset.label} | ${asset.startSec.toStringAsFixed(1)}s → ${(asset.startSec + (asset.durationSec > 0 ? asset.durationSec : 10.0)).toStringAsFixed(1)}s',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.white.withOpacity(0.5),
                    fontFamily: 'monospace',
                  ),
                );
              }),
            ),
        ],
      ),
    );
  }

  Widget _toolButton(IconData icon, String tooltip, _EditorTool tool) {
    final isActive = _activeTool == tool;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: () => setState(() => _activeTool = tool),
        child: Container(
          width: 28,
          height: 28,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: isActive
                ? const Color(0xFF6C5CE7).withOpacity(0.3)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: isActive
                ? Border.all(color: const Color(0xFF6C5CE7).withOpacity(0.6))
                : null,
          ),
          child: Icon(icon, size: 16,
              color: isActive ? const Color(0xFF6C5CE7) : Colors.white38),
        ),
      ),
    );
  }

  Widget _actionButton(IconData icon, String tooltip, VoidCallback? onTap) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(icon, size: 16,
              color: onTap != null ? Colors.white54 : Colors.white.withOpacity(0.2)),
        ),
      ),
    );
  }

  // ─── Shared helpers ───


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

  Widget _buildTrackLabel(String name, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          border: const Border(bottom: BorderSide(color: Colors.white10)),
          color: color.withOpacity(0.05),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: color.withOpacity(0.7)),
            const SizedBox(width: 4),
            Text(
              name,
              style: TextStyle(fontSize: 11, color: color.withOpacity(0.8), fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrackRow(
    Color color, {
    required TimelineTrack track,
    List<TimelineAsset> assets = const [],
    String? extraLabel,
  }) {
    return Expanded(
      child: DragTarget<TimelineAsset>(
        onAcceptWithDetails: (details) {
          ref.read(projectProvider.notifier).moveAssetToTrack(details.data.id, track);
        },
        builder: (context, candidateData, rejectedData) {
          final isHovering = candidateData.isNotEmpty;
          return Container(
            decoration: BoxDecoration(
              border: const Border(bottom: BorderSide(color: Colors.white10)),
              color: isHovering ? color.withOpacity(0.25) : color.withOpacity(0.05),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Background grid lines every 5 seconds
                    ...List.generate(
                      (constraints.maxWidth / (_pixelsPerSec * 5)).ceil() + 1,
                      (i) {
                        final x = i * 5.0 * _pixelsPerSec;
                        return Positioned(
                          left: x,
                          top: 0,
                          bottom: 0,
                          child: Container(
                            width: 1,
                            color: Colors.white.withOpacity(0.03),
                          ),
                        );
                      },
                    ),
                    // Asset clips positioned by startSec
                    ...assets.map((asset) {
                      final left = asset.startSec * _pixelsPerSec;
                      final clipDur = asset.durationSec > 0 ? asset.durationSec : 10.0;
                      final width = (clipDur * _pixelsPerSec).clamp(40.0, double.infinity);

                      return Positioned(
                        left: left,
                        top: 2,
                        bottom: 2,
                        width: width,
                        child: _buildTimelineClip(asset, color),
                      );
                    }),
                    // Extra label (e.g., voiceover, captions) when no real assets
                    if (assets.isEmpty && extraLabel != null)
                      Positioned(
                        left: 0,
                        top: 2,
                        bottom: 2,
                        width: 200,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.3),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: color.withOpacity(0.5)),
                          ),
                          alignment: Alignment.centerLeft,
                          child: Text(
                            extraLabel,
                            style: const TextStyle(fontSize: 10, color: Colors.white54),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// Individual clip on the timeline — draggable horizontally, resizable from edges.
  Widget _buildTimelineClip(TimelineAsset asset, Color color) {
    final isSelected = asset.id == _selectedAssetId;
    final isDragging = asset.id == _draggingAssetId;

    return Stack(
      children: [
        // Main clip body — horizontal drag to move
        Positioned.fill(
          left: 6,  // leave space for left resize handle
          right: 6, // leave space for right resize handle
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              setState(() {
                _selectedAssetId = asset.id;
                _rightPanel = _RightPanel.assetProperties;
              });
            },
            onHorizontalDragStart: (_) {
              setState(() => _draggingAssetId = asset.id);
            },
            onHorizontalDragUpdate: (details) {
              if (asset.locked) return;
              final deltaSec = details.delta.dx / _pixelsPerSec;
              final rawStart = (asset.startSec + deltaSec).clamp(0.0, 300.0);
              ref.read(projectProvider.notifier).updateAsset(
                asset.id,
                (a) => a.copyWith(startSec: _snapTime(rawStart)),
              );
            },
            onHorizontalDragEnd: (_) {
              setState(() => _draggingAssetId = null);
            },
            child: MouseRegion(
              cursor: asset.locked
                  ? SystemMouseCursors.forbidden
                  : isDragging
                      ? SystemMouseCursors.grabbing
                      : SystemMouseCursors.grab,
              child: Container(
                decoration: BoxDecoration(
                  color: isSelected
                      ? color.withOpacity(0.7)
                      : isDragging
                          ? color.withOpacity(0.6)
                          : color.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: isSelected
                        ? Colors.white54
                        : isDragging
                            ? Colors.white38
                            : color.withOpacity(0.6),
                    width: isSelected ? 2 : 1,
                  ),
                  boxShadow: isDragging
                      ? [BoxShadow(color: color.withOpacity(0.4), blurRadius: 8)]
                      : null,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Row(
                  children: [
                    if (!asset.visible)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(Icons.visibility_off, size: 10,
                            color: Colors.white.withOpacity(0.4)),
                      ),
                    if (asset.locked)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(Icons.lock, size: 10,
                            color: Colors.orangeAccent.withOpacity(0.6)),
                      ),
                    Flexible(
                      child: Text(
                        '${asset.label}${asset.speed != 1.0 ? " (${asset.speed}x)" : ""}',
                        style: TextStyle(
                          fontSize: 10,
                          color: asset.visible ? Colors.white70 : Colors.white30,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    // Show duration
                    Text(
                      '${asset.durationSec > 0 ? asset.durationSec.toStringAsFixed(1) : "10.0"}s',
                      style: TextStyle(
                        fontSize: 8,
                        color: Colors.white.withOpacity(0.3),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Left edge resize handle
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 6,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (details) {
              if (asset.locked) return;
              final deltaSec = details.delta.dx / _pixelsPerSec;
              final curDur = asset.durationSec > 0 ? asset.durationSec : 10.0;
              final maxStartDelta = curDur - 0.5;
              final actualDelta = deltaSec.clamp(-asset.startSec, maxStartDelta);
              ref.read(projectProvider.notifier).updateAsset(
                asset.id,
                (a) => a.copyWith(
                  startSec: a.startSec + actualDelta,
                  durationSec: (curDur - actualDelta).clamp(0.5, 300.0),
                ),
              );
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: Container(
                decoration: BoxDecoration(
                  color: isSelected ? color.withOpacity(0.9) : color.withOpacity(0.6),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(4),
                    bottomLeft: Radius.circular(4),
                  ),
                ),
              ),
            ),
          ),
        ),
        // Right edge resize handle
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: 6,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (details) {
              if (asset.locked) return;
              final deltaSec = details.delta.dx / _pixelsPerSec;
              final curDur = asset.durationSec > 0 ? asset.durationSec : 10.0;
              ref.read(projectProvider.notifier).updateAsset(
                asset.id,
                (a) => a.copyWith(
                  durationSec: (curDur + deltaSec).clamp(0.5, 300.0),
                ),
              );
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: Container(
                decoration: BoxDecoration(
                  color: isSelected ? color.withOpacity(0.9) : color.withOpacity(0.6),
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(4),
                    bottomRight: Radius.circular(4),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

enum _RightPanel { none, stockFootage, textEditor, voicePicker, layers, assetProperties, aiCreate }

enum _SelectedTextElement { none, title, body }

enum _EditorTool { select, razor, hand }

/// Paints time ruler ticks and labels
class _TimeRulerPainter extends CustomPainter {
  final double pixelsPerSec;
  _TimeRulerPainter({required this.pixelsPerSec});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x33FFFFFF)
      ..strokeWidth = 1;

    // Determine tick interval based on zoom
    double interval;
    if (pixelsPerSec < 5) {
      interval = 10.0;
    } else if (pixelsPerSec < 15) {
      interval = 5.0;
    } else if (pixelsPerSec < 40) {
      interval = 2.0;
    } else if (pixelsPerSec > 100) {
      interval = 0.5;
    } else {
      interval = 1.0;
    }

    double sec = 0;
    int tickIndex = 0;
    while (sec * pixelsPerSec < size.width) {
      final x = sec * pixelsPerSec;
      final isMajor = tickIndex % 5 == 0;

      canvas.drawLine(
        Offset(x, isMajor ? 0 : size.height * 0.5),
        Offset(x, size.height),
        paint,
      );

      if (isMajor) {
        final totalSec = sec.round();
        final minutes = totalSec ~/ 60;
        final secs = totalSec % 60;
        final label = '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
        final tp = TextPainter(
          text: TextSpan(
            text: label,
            style: const TextStyle(fontSize: 9, color: Color(0x66FFFFFF)),
          ),
          textDirection: TextDirection.ltr,
        );
        tp.layout();
        tp.paint(canvas, Offset(x + 3, 2));
      }

      sec += interval;
      tickIndex++;
    }
  }

  @override
  bool shouldRepaint(covariant _TimeRulerPainter oldDelegate) =>
      oldDelegate.pixelsPerSec != pixelsPerSec;
}

/// Paints the red playhead triangle at the top
class _PlayheadTrianglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.redAccent;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

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
