import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/ipc/ipc_client.dart';
import '../../../core/ipc/ipc_message.dart';
import '../../../core/services/api_key_service.dart';
import '../../../core/services/project_state.dart';
import '../../../core/ui/video_player_overlay.dart';
import '../providers/editor_layout_provider.dart';
import 'script_generator_panel.dart';

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

/// Returns a [TextStyle] that uses the Google Fonts package to load
/// the given [fontFamily] dynamically.  Falls back to the raw family name.
TextStyle _googleFontStyle(String fontFamily, {
  double? fontSize,
  FontWeight? fontWeight,
  FontStyle? fontStyle,
  Color? color,
  double? height,
  List<Shadow>? shadows,
}) {
  final base = TextStyle(
    fontSize: fontSize,
    fontWeight: fontWeight,
    fontStyle: fontStyle,
    color: color,
    height: height,
    shadows: shadows,
  );
  try {
    return GoogleFonts.getFont(fontFamily, textStyle: base);
  } catch (_) {
    return base.copyWith(fontFamily: fontFamily);
  }
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

  // Music search
  final _musicSearchController = TextEditingController();
  List<Map<String, dynamic>> _musicResults = [];
  bool _isSearchingMusic = false;

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

  // Resizable right panel width
  double _rightPanelWidth = 340.0;
  static const double _minRightPanelWidth = 280.0;
  static const double _maxRightPanelWidth = 600.0;

  // Whether the toolbar strip is visible (toggled via View menu)
  bool _toolbarVisible = true;

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
    _musicSearchController.dispose();
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

  /// Convert a 0xAARRGGBB int to FFmpeg color string like "0xRRGGBB".
  static String _hexToFfmpegColor(int hex) {
    final r = (hex >> 16) & 0xFF;
    final g = (hex >> 8) & 0xFF;
    final b = hex & 0xFF;
    return '0x${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}';
  }

  /// Convert a 0xAARRGGBB int to FFmpeg bg color like "0xRRGGBB@0.5".
  static String _hexToFfmpegBgColor(int hex) {
    final a = ((hex >> 24) & 0xFF) / 255.0;
    final r = (hex >> 16) & 0xFF;
    final g = (hex >> 8) & 0xFF;
    final b = hex & 0xFF;
    final colorHex = '0x${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}';
    return '$colorHex@${a.toStringAsFixed(2)}';
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

      final titleStyle = project.titleStyle;
      final bodyStyle = project.captionStyle;

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

        // ─── Title styling ───
        // Scale font size from abstract CaptionStyle units to 1080p render pixels.
        // Preview uses fontSize * 0.45 on a ~360px frame; render is 1080px (3× wider).
        'title_font_family': titleStyle.fontFamily,
        'title_font_size_px': (titleStyle.fontSize * 1.35).round(),
        'title_bold': titleStyle.isBold,
        'title_italic': titleStyle.isItalic,
        'title_color': _hexToFfmpegColor(titleStyle.colorHex),
        'title_shadow': titleStyle.hasBorder,
        'title_pos_x': titleStyle.positionX,
        'title_pos_y': titleStyle.positionY,
        'title_bg_enabled': ((titleStyle.bgColorHex >> 24) & 0xFF) > 0,
        'title_bg_color': _hexToFfmpegBgColor(titleStyle.bgColorHex),

        // ─── Body styling ───
        // Body preview uses fontSize * 0.3 on ~360px → 0.9× for 1080p
        'body_font_family': bodyStyle.fontFamily,
        'body_font_size_px': (bodyStyle.fontSize * 0.9).round(),
        'body_bold': bodyStyle.isBold,
        'body_italic': bodyStyle.isItalic,
        'body_color': _hexToFfmpegColor(bodyStyle.colorHex),
        'body_shadow': bodyStyle.hasBorder,
        'text_pos_x': bodyStyle.positionX,
        'text_pos_y': bodyStyle.positionY,
        'body_bg_enabled': ((bodyStyle.bgColorHex >> 24) & 0xFF) > 0,
        'body_bg_color': _hexToFfmpegBgColor(bodyStyle.bgColorHex),

        // ─── Box dimensions ───
        if (bodyStyle.boxWidth != null) 'text_box_w': bodyStyle.boxWidth,
        if (bodyStyle.boxHeight != null) 'text_box_h': bodyStyle.boxHeight,

        // ─── Pre-generated TTS audio (skip re-generation) ───
        if (_ttsAudioPath != null) 'tts_audio_path': _ttsAudioPath,
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
              if (outputPath.isNotEmpty) ...[
                OutlinedButton.icon(
                  icon: const Icon(Icons.play_circle_outline, size: 18),
                  label: const Text('Preview'),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    VideoPlayerOverlay.show(context, url: outputPath, title: 'Render Preview');
                  },
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Open Folder'),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _openOutputFolder(outputPath);
                  },
                ),
              ],
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

    final layout = ref.watch(editorLayoutProvider);

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
      child: Column(
        children: [
          // ─── MENU BAR (File, Edit, View, Help) ───
          _buildMenuBar(project),
          // ─── ACTION TOOLBAR (toggleable via View menu) ───
          if (_toolbarVisible)
            _buildActionToolbar(project),
          // ─── MAIN CONTENT AREA ───
          Expanded(
            child: Row(
              children: [
                // Main editor area (preview + timeline)
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
                      // Transport controls bar
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
                // Right side panel (resizable with drag handle)
                if (_rightPanel != _RightPanel.none) ...[
                  // Resizable drag handle (vertical)
                  GestureDetector(
                    onHorizontalDragUpdate: (details) {
                      setState(() {
                        _rightPanelWidth = (_rightPanelWidth - details.delta.dx)
                            .clamp(_minRightPanelWidth, _maxRightPanelWidth);
                      });
                    },
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeColumn,
                      child: Container(
                        width: 6,
                        color: const Color(0xFF1A1A2A),
                        child: Center(
                          child: Container(
                            width: 2,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: _rightPanelWidth,
                    child: Column(
                      children: [
                        // Panel header with title and close button
                        _buildPanelHeader(
                          title: _rightPanelTitle,
                          onClose: () => setState(() {
                            _rightPanel = _RightPanel.none;
                            _selectedTextElement = _SelectedTextElement.none;
                          }),
                        ),
                        Expanded(
                          child: switch (_rightPanel) {
                            _RightPanel.stockFootage => _buildStockFootagePanel(),
                            _RightPanel.textEditor => _buildTextEditorPanel(project),
                            _RightPanel.voicePicker => _buildVoicePanel(project),
                            _RightPanel.assetProperties => _buildAssetPropertiesPanel(project),
                            _RightPanel.aiCreate => _buildAiCreatePanel(project),
                            _RightPanel.music => _buildMusicPanel(project),
                            _ => _buildLayersPanel(project),
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Right panel title getter ───
  String get _rightPanelTitle => switch (_rightPanel) {
        _RightPanel.stockFootage => 'Stock Footage',
        _RightPanel.textEditor => 'Text / Font',
        _RightPanel.voicePicker => 'Voice Picker',
        _RightPanel.layers => 'Layers',
        _RightPanel.assetProperties => 'Properties',
        _RightPanel.aiCreate => 'AI Create',
        _RightPanel.music => 'Music & Sounds',
        _RightPanel.none => '',
      };

  // ─── Menu Bar (File, Edit, View, Help) — Adobe-style ───
  Widget _buildMenuBar(ProjectState project) {
    return Container(
      height: 30,
      color: const Color(0xFF18182A),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          _menuBarButton('File', [
            _MenuAction('Import File...', Icons.folder_open, _isBusy ? null : _importVideo),
            _MenuAction('Download URL...', Icons.download, _isBusy ? null : () => _downloadVideo()),
            _MenuAction.separator(),
            _MenuAction('Generate Proxy', Icons.high_quality,
                _importedVideoPath != null && !_isBusy && _proxyPath == null
                    ? _generateProxy : null),
            _MenuAction('Transcribe', Icons.subtitles,
                _importedVideoPath != null && !_isBusy && _transcriptSegments.isEmpty
                    ? _transcribeVideo : null),
            _MenuAction.separator(),
            _MenuAction('Render Short...', Icons.movie_creation,
                project.scriptText != null && !_isBusy ? _renderVideo : null),
          ]),
          _menuBarButton('Edit', [
            _MenuAction('Split at Playhead', Icons.splitscreen,
                _selectedAssetId != null ? _splitAtPlayhead : null, shortcut: 'S'),
            _MenuAction('Duplicate', Icons.copy,
                _selectedAssetId != null ? _duplicateSelected : null, shortcut: 'Ctrl+D'),
            _MenuAction('Delete', Icons.delete_outline,
                _selectedAssetId != null ? _deleteSelected : null, shortcut: 'Del'),
            _MenuAction.separator(),
            _MenuAction('Select Tool', Icons.near_me,
                () => setState(() => _activeTool = _EditorTool.select), shortcut: 'V'),
            _MenuAction('Razor Tool', Icons.content_cut,
                () => setState(() => _activeTool = _EditorTool.razor), shortcut: 'C'),
            _MenuAction('Hand Tool', Icons.pan_tool_alt,
                () => setState(() => _activeTool = _EditorTool.hand), shortcut: 'H'),
          ]),
          _menuBarButton('View', [
            _MenuAction(
              _toolbarVisible ? '✓  Toolbar' : '    Toolbar',
              Icons.build_outlined,
              () => setState(() => _toolbarVisible = !_toolbarVisible),
            ),
            _MenuAction(
              _rightPanel != _RightPanel.none ? '✓  Right Panel' : '    Right Panel',
              Icons.view_sidebar_outlined,
              () => setState(() {
                if (_rightPanel != _RightPanel.none) {
                  _rightPanel = _RightPanel.none;
                } else {
                  _rightPanel = _RightPanel.layers;
                }
              }),
            ),
            _MenuAction.separator(),
            _MenuAction('Stock Footage', Icons.movie_filter,
                () => setState(() => _rightPanel = _RightPanel.stockFootage)),
            _MenuAction('Layers', Icons.layers,
                () => setState(() => _rightPanel = _RightPanel.layers)),
            _MenuAction('Text / Font', Icons.text_fields,
                project.scriptText != null
                    ? () => setState(() => _rightPanel = _RightPanel.textEditor) : null),
            _MenuAction('Voice Picker', Icons.record_voice_over,
                project.scriptText != null
                    ? () => setState(() => _rightPanel = _RightPanel.voicePicker) : null),
            _MenuAction('AI Create', Icons.auto_awesome,
                () => setState(() => _rightPanel = _RightPanel.aiCreate)),
            _MenuAction.separator(),
            _MenuAction(
              _snapEnabled ? '✓  Snap to Grid' : '    Snap to Grid',
              Icons.grid_on,
              () => setState(() => _snapEnabled = !_snapEnabled),
            ),
          ]),
          _menuBarButton('Help', [
            _MenuAction('Keyboard Shortcuts', Icons.keyboard, () {
              _showKeyboardShortcutsDialog();
            }),
            _MenuAction('About ClipMaster', Icons.info_outline, () {
              showAboutDialog(
                context: context,
                applicationName: 'ClipMaster Pro',
                applicationVersion: '1.0.0',
                applicationIcon: const Icon(Icons.movie_creation, color: Color(0xFF6C5CE7), size: 36),
              );
            }),
          ]),
          const Spacer(),
          // Current project info in menu bar
          if (_importedVideoName != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                _importedVideoName!,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withOpacity(0.3),
                  fontFamily: 'monospace',
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  Widget _menuBarButton(String label, List<_MenuAction> actions) {
    return PopupMenuButton<int>(
      offset: const Offset(0, 30),
      color: const Color(0xFF22223A),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: Colors.white.withOpacity(0.08)),
      ),
      itemBuilder: (context) {
        final items = <PopupMenuEntry<int>>[];
        for (int i = 0; i < actions.length; i++) {
          final a = actions[i];
          if (a.isSeparator) {
            items.add(const PopupMenuDivider(height: 8));
          } else {
            items.add(PopupMenuItem<int>(
              value: i,
              enabled: a.onTap != null,
              height: 32,
              child: Row(
                children: [
                  Icon(a.icon, size: 15,
                      color: a.onTap != null ? Colors.white54 : Colors.white12),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      a.label,
                      style: TextStyle(
                        fontSize: 12,
                        color: a.onTap != null ? Colors.white70 : Colors.white24,
                      ),
                    ),
                  ),
                  if (a.shortcut != null)
                    Text(
                      a.shortcut!,
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.white.withOpacity(0.25),
                        fontFamily: 'monospace',
                      ),
                    ),
                ],
              ),
            ));
          }
        }
        return items;
      },
      onSelected: (index) {
        if (index >= 0 && index < actions.length && actions[index].onTap != null) {
          actions[index].onTap!();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.white.withOpacity(0.6),
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  void _showKeyboardShortcutsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Keyboard Shortcuts'),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _shortcutRow('Space', 'Play / Pause'),
              _shortcutRow('V', 'Select Tool'),
              _shortcutRow('C', 'Razor Tool'),
              _shortcutRow('H', 'Hand Tool'),
              _shortcutRow('S', 'Split at Playhead'),
              _shortcutRow('Del', 'Delete Selected'),
              _shortcutRow('Ctrl+D', 'Duplicate'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _shortcutRow(String key, String desc) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            child: Text(key, style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.white70)),
          ),
          const SizedBox(width: 12),
          Text(desc, style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.5))),
        ],
      ),
    );
  }

  // ─── Action Toolbar (converted from chips) ───
  Widget _buildActionToolbar(ProjectState project) {
    return Container(
      height: 38,
      color: const Color(0xFF1A1A2E),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          // File operations
          _toolbarIconButton(Icons.folder_open, 'Import File',
              _isBusy ? null : _importVideo),
          _toolbarIconButton(Icons.download, 'Download URL',
              _isBusy ? null : () => _downloadVideo()),
          _toolbarDivider(),
          // Processing
          if (_importedVideoPath != null) ...[
            _toolbarButton(
              icon: Icons.high_quality,
              label: _proxyPath != null ? 'Proxy' : 'Proxy',
              active: _proxyPath != null,
              busy: _isGeneratingProxy,
              onTap: _isBusy || _proxyPath != null ? null : _generateProxy,
            ),
            _toolbarButton(
              icon: Icons.subtitles,
              label: _transcriptSegments.isNotEmpty
                  ? '${_transcriptSegments.length} Captions'
                  : 'Transcribe',
              active: _transcriptSegments.isNotEmpty,
              busy: _isTranscribing,
              onTap: _isBusy || _transcriptSegments.isNotEmpty
                  ? null
                  : _transcribeVideo,
            ),
            _toolbarDivider(),
          ],
          // Panel toggles
          _toolbarButton(
            icon: Icons.movie_filter,
            label: 'Stock Footage',
            active: _rightPanel == _RightPanel.stockFootage,
            onTap: () => setState(() {
              _rightPanel = _rightPanel == _RightPanel.stockFootage
                  ? _RightPanel.none
                  : _RightPanel.stockFootage;
            }),
          ),
          _toolbarButton(
            icon: Icons.layers,
            label: 'Layers',
            active: _rightPanel == _RightPanel.layers,
            onTap: () => setState(() {
              _rightPanel = _rightPanel == _RightPanel.layers
                  ? _RightPanel.none
                  : _RightPanel.layers;
            }),
          ),
          if (project.scriptText != null) ...[
            _toolbarButton(
              icon: Icons.text_fields,
              label: 'Text / Font',
              active: _rightPanel == _RightPanel.textEditor,
              onTap: () => setState(() {
                _rightPanel = _rightPanel == _RightPanel.textEditor
                    ? _RightPanel.none
                    : _RightPanel.textEditor;
              }),
            ),
            _toolbarButton(
              icon: Icons.record_voice_over,
              label: project.selectedVoice.label,
              active: _rightPanel == _RightPanel.voicePicker,
              onTap: () => setState(() {
                _rightPanel = _rightPanel == _RightPanel.voicePicker
                    ? _RightPanel.none
                    : _RightPanel.voicePicker;
              }),
            ),
          ],
          _toolbarButton(
            icon: Icons.music_note,
            label: 'Music',
            active: _rightPanel == _RightPanel.music,
            onTap: () => setState(() {
              _rightPanel = _rightPanel == _RightPanel.music
                  ? _RightPanel.none
                  : _RightPanel.music;
            }),
          ),
          _toolbarButton(
            icon: Icons.auto_awesome,
            label: 'AI Create',
            active: _rightPanel == _RightPanel.aiCreate,
            onTap: () => setState(() {
              _rightPanel = _rightPanel == _RightPanel.aiCreate
                  ? _RightPanel.none
                  : _RightPanel.aiCreate;
            }),
          ),
          const Spacer(),
          // Render button (in toolbar)
          if (project.scriptText != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: FilledButton.icon(
                onPressed: _isBusy ? null : _renderVideo,
                icon: _isRendering
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.movie_creation, size: 16),
                label: Text(
                  _isRendering ? 'Rendering...' : 'Render Short',
                  style: const TextStyle(fontSize: 12),
                ),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  backgroundColor: const Color(0xFF6C5CE7),
                  minimumSize: const Size(0, 28),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _toolbarIconButton(IconData icon, String tooltip, VoidCallback? onTap) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          width: 30,
          height: 30,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          child: Icon(icon, size: 16,
              color: onTap != null ? Colors.white54 : Colors.white24),
        ),
      ),
    );
  }

  Widget _toolbarButton({
    required IconData icon,
    required String label,
    bool active = false,
    bool busy = false,
    VoidCallback? onTap,
  }) {
    final color = active ? const Color(0xFF6C5CE7) : Colors.white54;
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          height: 28,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: active
                ? const Color(0xFF6C5CE7).withOpacity(0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: active
                ? Border.all(color: const Color(0xFF6C5CE7).withOpacity(0.4))
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                SizedBox(
                  width: 13, height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2, color: color),
                )
              else
                Icon(icon, size: 14, color: color),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: active ? const Color(0xFF6C5CE7) : Colors.white54,
                  fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbarDivider() {
    return Container(
      width: 1,
      height: 20,
      color: Colors.white10,
      margin: const EdgeInsets.symmetric(horizontal: 6),
    );
  }

  // ─── Panel Header with close button ───
  Widget _buildPanelHeader({
    required String title,
    required VoidCallback onClose,
  }) {
    return Container(
      height: 32,
      color: const Color(0xFF1A1A2E),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.white60,
              letterSpacing: 0.5,
            ),
          ),
          const Spacer(),
          InkWell(
            onTap: onClose,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.close, size: 14,
                  color: Colors.white.withOpacity(0.4)),
            ),
          ),
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
            'Import a video or generate a script with AI',
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
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => setState(() {
              _rightPanel = _RightPanel.aiCreate;
            }),
            icon: const Icon(Icons.auto_awesome, size: 18),
            label: const Text('Generate Script'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF6C5CE7),
            ),
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

    // ─── Adobe-style Program Monitor ───
    // The preview fills the entire main area — this IS your editing canvas.
    // All controls (text, layers, etc.) are in the right panel.
    return Padding(
      padding: const EdgeInsets.all(8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: 200.0,
                maxWidth: (constraints.maxWidth).clamp(200, 600),
                maxHeight: constraints.maxHeight,
              ),
              child: AspectRatio(
                aspectRatio: 9 / 16,
                child: _buildPhonePreview(project),
              ),
            ),
          );
        },
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

    // Check for any video source: video track first, then b-roll
    final videoAssets =
        project.assets.where((a) => a.track == TimelineTrack.video).toList();
    final brollAssets =
        project.assets.where((a) => a.track == TimelineTrack.broll).toList();
    // Try video track URL, then b-roll URL, then b-roll download URL
    String bgUrl = '';
    String? bgThumbnail;
    if (videoAssets.isNotEmpty) {
      bgUrl = videoAssets.first.url ?? videoAssets.first.thumbnailUrl ?? '';
      bgThumbnail = videoAssets.first.thumbnailUrl;
    } else if (brollAssets.isNotEmpty) {
      // Use first b-roll clip as preview background
      final first = brollAssets.first;
      bgUrl = first.url ?? '';
      bgThumbnail = first.thumbnailUrl ?? first.url;
    }

    // Auto-load background from URL if no local video is loaded
    // Schedule for after build — never call _initPreviewPlayer during build.
    if (bgUrl.isNotEmpty && _previewController == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _previewController == null) {
          _initPreviewPlayer(bgUrl);
        }
      });
    }

    return Column(
        children: [
          // WYSIWYG preview canvas — this is exactly what will render
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0A0A14),
                border: Border.all(
                  color: Colors.white.withOpacity(0.08),
                  width: 1,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: ClipRect(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final frameW = constraints.maxWidth;
                    final frameH = constraints.maxHeight;
                    // Scale text relative to frame width (base ref: 360px phone width)
                    final textScale = (frameW / 360).clamp(0.5, 1.5);

                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        // Background layer: video > thumbnail > gradient
                        if (_previewController != null)
                          Video(
                            controller: _previewController!,
                            controls: NoVideoControls,
                            fit: BoxFit.cover,
                          )
                        else if (bgThumbnail != null && bgThumbnail.isNotEmpty)
                          Image.network(
                            bgThumbnail,
                            fit: BoxFit.cover,
                            width: frameW,
                            height: frameH,
                            errorBuilder: (_, __, ___) => Container(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [Color(0xFF1A1A2E), Color(0xFF0A0A14)],
                                ),
                              ),
                            ),
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
                        // Title text — resizable, draggable
                        if (hasTitle)
                          _buildResizableTextBox(
                            frameW: frameW,
                            frameH: frameH,
                            textScale: textScale,
                            captionStyle: project.titleStyle,
                            text: titleText,
                            element: _SelectedTextElement.title,
                            isTitle: true,
                            project: project,
                            maxLines: 4,
                            fontScaleFactor: 0.45,
                          ),
                        // Body text — resizable, draggable
                        if (hasScript)
                          _buildResizableTextBox(
                            frameW: frameW,
                            frameH: frameH,
                            textScale: textScale,
                            captionStyle: style,
                            text: scriptText,
                            element: _SelectedTextElement.body,
                            isTitle: false,
                            project: project,
                            maxLines: 12,
                            fontScaleFactor: 0.3,
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
          // Preview label — WYSIWYG indicator
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '9:16 WYSIWYG Preview — what you see is what renders',
              style: TextStyle(
                fontSize: 9,
                color: Colors.white.withOpacity(0.2),
              ),
            ),
          ),
        ],
    );
  }

  /// Shows a dialog for inline text editing (double-click on text in preview).
  void _showInlineTextEditor({
    required bool isTitle,
    required String currentText,
    required ProjectState project,
  }) {
    final controller = TextEditingController(text: currentText);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(isTitle ? 'Edit Title' : 'Edit Body Text'),
        content: SizedBox(
          width: 400,
          child: TextField(
            controller: controller,
            maxLines: isTitle ? 3 : 10,
            autofocus: true,
            style: const TextStyle(fontSize: 14, color: Colors.white),
            decoration: InputDecoration(
              hintText: isTitle ? 'Enter title...' : 'Enter body text...',
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.2)),
              filled: true,
              fillColor: Colors.white.withOpacity(0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF6C5CE7)),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final newText = controller.text;
              if (isTitle) {
                ref.read(projectProvider.notifier).setScript(
                  title: newText,
                  text: project.scriptText,
                );
              } else {
                ref.read(projectProvider.notifier).setScript(
                  title: project.scriptTitle,
                  text: newText,
                );
              }
              Navigator.of(ctx).pop();
            },
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF6C5CE7),
            ),
            child: const Text('Apply'),
          ),
        ],
      ),
    ).then((_) => controller.dispose());
  }

  /// Builds a resizable, draggable text box overlay in the preview canvas.
  Widget _buildResizableTextBox({
    required double frameW,
    required double frameH,
    required double textScale,
    required CaptionStyle captionStyle,
    required String text,
    required _SelectedTextElement element,
    required bool isTitle,
    required ProjectState project,
    required int maxLines,
    required double fontScaleFactor,
  }) {
    final isSelected = _selectedTextElement == element;
    final boxW = captionStyle.boxWidth != null
        ? captionStyle.boxWidth! * frameW
        : frameW - 24 * textScale;
    final boxH = captionStyle.boxHeight != null
        ? captionStyle.boxHeight! * frameH
        : null; // null = auto height

    final topPos = captionStyle.positionY * frameH - (isTitle ? 0 : 30 * textScale);
    final leftPos = (frameW - boxW) / 2; // center horizontally

    void updateStyle(CaptionStyle newStyle) {
      if (isTitle) {
        ref.read(projectProvider.notifier).setTitleStyle(newStyle);
      } else {
        ref.read(projectProvider.notifier).setCaptionStyle(newStyle);
      }
    }

    return Positioned(
      top: topPos.clamp(0, frameH - 20),
      left: leftPos.clamp(0, frameW - 40),
      child: SizedBox(
        width: boxW.clamp(40, frameW),
        height: boxH?.clamp(20, frameH * 0.8),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Main text box — draggable
            GestureDetector(
              onTap: () {
                setState(() {
                  _selectedTextElement = element;
                  _rightPanel = _RightPanel.textEditor;
                });
              },
              onDoubleTap: () => _showInlineTextEditor(
                isTitle: isTitle,
                currentText: text,
                project: project,
              ),
              onPanUpdate: (details) {
                final newY = (captionStyle.positionY + details.delta.dy / frameH)
                    .clamp(0.03, 0.92);
                updateStyle(captionStyle.copyWith(positionY: newY));
              },
              child: MouseRegion(
                cursor: SystemMouseCursors.move,
                child: Container(
                  width: boxW,
                  height: boxH,
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: isSelected
                          ? const Color(0xFF6C5CE7)
                          : const Color(0xFF6C5CE7).withOpacity(0.3),
                      width: isSelected ? 1.5 : 0.5,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    decoration: BoxDecoration(
                      color: Color(captionStyle.bgColorHex),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      text,
                      textAlign: TextAlign.center,
                      maxLines: maxLines,
                      overflow: TextOverflow.ellipsis,
                      style: _googleFontStyle(
                        captionStyle.fontFamily,
                        fontSize: (captionStyle.fontSize * fontScaleFactor * textScale)
                            .clamp(7.0, 36.0),
                        fontWeight: captionStyle.isBold ? FontWeight.w800 : FontWeight.w400,
                        fontStyle: captionStyle.isItalic ? FontStyle.italic : FontStyle.normal,
                        color: Color(captionStyle.colorHex),
                        height: 1.4,
                        shadows: captionStyle.hasBorder
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
            ),
            // Resize handles (only when selected)
            if (isSelected) ...[
              // Bottom-right corner handle
              Positioned(
                right: -5,
                bottom: boxH != null ? -5 : null,
                top: boxH == null ? null : null,
                child: GestureDetector(
                  onPanUpdate: (details) {
                    final newW = ((captionStyle.boxWidth ?? (boxW / frameW)) +
                            details.delta.dx / frameW)
                        .clamp(0.15, 0.95);
                    if (boxH != null || details.delta.dy.abs() > 2) {
                      final newH = ((captionStyle.boxHeight ?? (60 / frameH)) +
                              details.delta.dy / frameH)
                          .clamp(0.05, 0.7);
                      updateStyle(captionStyle.copyWith(boxWidth: newW, boxHeight: newH));
                    } else {
                      updateStyle(captionStyle.copyWith(boxWidth: newW));
                    }
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeDownRight,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: const Color(0xFF6C5CE7),
                        borderRadius: BorderRadius.circular(2),
                        border: Border.all(color: Colors.white, width: 1),
                      ),
                    ),
                  ),
                ),
              ),
              // Bottom-left corner handle
              Positioned(
                left: -5,
                bottom: boxH != null ? -5 : null,
                child: GestureDetector(
                  onPanUpdate: (details) {
                    final newW = ((captionStyle.boxWidth ?? (boxW / frameW)) -
                            details.delta.dx / frameW)
                        .clamp(0.15, 0.95);
                    if (boxH != null || details.delta.dy.abs() > 2) {
                      final newH = ((captionStyle.boxHeight ?? (60 / frameH)) +
                              details.delta.dy / frameH)
                          .clamp(0.05, 0.7);
                      updateStyle(captionStyle.copyWith(boxWidth: newW, boxHeight: newH));
                    } else {
                      updateStyle(captionStyle.copyWith(boxWidth: newW));
                    }
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeDownLeft,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: const Color(0xFF6C5CE7),
                        borderRadius: BorderRadius.circular(2),
                        border: Border.all(color: Colors.white, width: 1),
                      ),
                    ),
                  ),
                ),
              ),
              // Right-center handle (width only)
              Positioned(
                right: -5,
                top: (boxH ?? 30) / 2 - 6,
                child: GestureDetector(
                  onPanUpdate: (details) {
                    final newW = ((captionStyle.boxWidth ?? (boxW / frameW)) +
                            details.delta.dx / frameW)
                        .clamp(0.15, 0.95);
                    updateStyle(captionStyle.copyWith(boxWidth: newW));
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeLeftRight,
                    child: Container(
                      width: 10,
                      height: 14,
                      decoration: BoxDecoration(
                        color: const Color(0xFF6C5CE7),
                        borderRadius: BorderRadius.circular(2),
                        border: Border.all(color: Colors.white, width: 1),
                      ),
                    ),
                  ),
                ),
              ),
              // Left-center handle (width only)
              Positioned(
                left: -5,
                top: (boxH ?? 30) / 2 - 6,
                child: GestureDetector(
                  onPanUpdate: (details) {
                    final newW = ((captionStyle.boxWidth ?? (boxW / frameW)) -
                            details.delta.dx / frameW)
                        .clamp(0.15, 0.95);
                    updateStyle(captionStyle.copyWith(boxWidth: newW));
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeLeftRight,
                    child: Container(
                      width: 10,
                      height: 14,
                      decoration: BoxDecoration(
                        color: const Color(0xFF6C5CE7),
                        borderRadius: BorderRadius.circular(2),
                        border: Border.all(color: Colors.white, width: 1),
                      ),
                    ),
                  ),
                ),
              ),
              // Size indicator
              Positioned(
                right: 0,
                top: -16,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6C5CE7),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    '${(boxW).toInt()}×${boxH?.toInt() ?? "auto"}',
                    style: const TextStyle(fontSize: 8, color: Colors.white),
                  ),
                ),
              ),
            ],
          ],
        ),
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
    final hasTitle = project.scriptTitle != null && project.scriptTitle!.isNotEmpty;
    final hasBody = project.scriptText != null && project.scriptText!.isNotEmpty;
    final hasAnyContent = allAssets.isNotEmpty || hasTitle || hasBody;

    return Container(
      color: const Color(0xFF1A1A2A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Text overlay virtual layers
          if (hasTitle || hasBody) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Text('Text Layers',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                      color: Colors.white.withOpacity(0.3), letterSpacing: 1)),
            ),
            if (hasTitle)
              _buildTextLayerItem(
                label: project.scriptTitle!,
                icon: Icons.title,
                color: const Color(0xFF82782D),
                isSelected: _selectedTextElement == _SelectedTextElement.title,
                onTap: () => setState(() {
                  _selectedTextElement = _SelectedTextElement.title;
                  _rightPanel = _RightPanel.textEditor;
                }),
                onVisibilityTap: () {
                  // Clear title to hide it
                  ref.read(projectProvider.notifier).setScript(
                    title: '',
                    text: project.scriptText,
                  );
                },
                visible: true,
              ),
            if (hasBody)
              _buildTextLayerItem(
                label: project.scriptText!,
                icon: Icons.notes,
                color: const Color(0xFF2D824A),
                isSelected: _selectedTextElement == _SelectedTextElement.body,
                onTap: () => setState(() {
                  _selectedTextElement = _SelectedTextElement.body;
                  _rightPanel = _RightPanel.textEditor;
                }),
                onVisibilityTap: () {
                  ref.read(projectProvider.notifier).setScript(
                    title: project.scriptTitle,
                    text: '',
                  );
                },
                visible: true,
              ),
            const Divider(height: 1),
            if (allAssets.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Text('Media Layers',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                        color: Colors.white.withOpacity(0.3), letterSpacing: 1)),
              ),
          ],
          // Asset list
          Expanded(
            child: !hasAnyContent
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.layers, size: 32,
                            color: Colors.white.withOpacity(0.1)),
                        const SizedBox(height: 8),
                        Text(
                          'No layers yet.\nImport media or generate a script.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withOpacity(0.3),
                          ),
                        ),
                      ],
                    ),
                  )
                : allAssets.isEmpty
                    ? const SizedBox.shrink()
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

  Widget _buildTextLayerItem({
    required String label,
    required IconData icon,
    required Color color,
    required bool isSelected,
    required VoidCallback onTap,
    required VoidCallback onVisibilityTap,
    required bool visible,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Card(
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
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 28,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(Icons.edit, size: 14,
                    color: Colors.white.withOpacity(0.3)),
              ],
            ),
          ),
        ),
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Icon(_trackIcon(asset.track), size: 16, color: trackColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    asset.label,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                InkWell(
                  onTap: () => setState(() => _rightPanel = _RightPanel.layers),
                  borderRadius: BorderRadius.circular(4),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.arrow_back, size: 14, color: Colors.white38),
                  ),
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
                  // ─── TEXT CONTENT EDITING ───
                  Text(
                    isTitle ? 'Title Text' : 'Body Text',
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                  const SizedBox(height: 6),
                  TextFormField(
                    key: ValueKey('text_content_${isTitle ? "title" : "body"}'),
                    initialValue: isTitle
                        ? (project.scriptTitle ?? '')
                        : (project.scriptText ?? ''),
                    maxLines: isTitle ? 2 : 8,
                    minLines: isTitle ? 1 : 3,
                    style: const TextStyle(fontSize: 13, color: Colors.white),
                    decoration: InputDecoration(
                      hintText: isTitle ? 'Enter title...' : 'Enter body text...',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.2)),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.05),
                      contentPadding: const EdgeInsets.all(10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: const BorderSide(color: Color(0xFF6C5CE7)),
                      ),
                    ),
                    onChanged: (value) {
                      if (isTitle) {
                        ref.read(projectProvider.notifier).setScript(
                          title: value,
                          text: project.scriptText,
                        );
                      } else {
                        ref.read(projectProvider.notifier).setScript(
                          title: project.scriptTitle,
                          text: value,
                        );
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  // ─── FONT FAMILY ───
                  const Text('Font Family',
                      style: TextStyle(fontSize: 11, color: Colors.white54)),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.white.withOpacity(0.1)),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: style.fontFamily,
                        isExpanded: true,
                        dropdownColor: const Color(0xFF22223A),
                        style: const TextStyle(fontSize: 13, color: Colors.white),
                        items: ['Inter', 'Roboto', 'Montserrat', 'Oswald', 'Lato', 'Poppins']
                            .map((f) => DropdownMenuItem(
                                value: f,
                                child: Text(f, style: _googleFontStyle(f, fontSize: 13))))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) {
                            updateStyle(style.copyWith(fontFamily: v));
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // ─── FONT SIZE ───
                  Row(
                    children: [
                      const Text('Size',
                          style: TextStyle(fontSize: 11, color: Colors.white54)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Slider(
                          value: style.fontSize.clamp(12, 72),
                          min: 12,
                          max: 72,
                          divisions: 30,
                          label: '${style.fontSize.toInt()}px',
                          onChanged: (v) {
                            updateStyle(style.copyWith(fontSize: v));
                          },
                        ),
                      ),
                      SizedBox(
                        width: 48,
                        child: Text(
                          '${style.fontSize.toInt()}px',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.white.withOpacity(0.5),
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // ─── BOLD / ITALIC / BORDER TOGGLES ───
                  Row(
                    children: [
                      _styleToggleButton(
                        icon: Icons.format_bold,
                        label: 'B',
                        active: style.isBold,
                        onTap: () => updateStyle(style.copyWith(isBold: !style.isBold)),
                      ),
                      const SizedBox(width: 6),
                      _styleToggleButton(
                        icon: Icons.format_italic,
                        label: 'I',
                        active: style.isItalic,
                        onTap: () => updateStyle(style.copyWith(isItalic: !style.isItalic)),
                      ),
                      const SizedBox(width: 6),
                      _styleToggleButton(
                        icon: Icons.border_color,
                        label: 'Shadow',
                        active: style.hasBorder,
                        onTap: () => updateStyle(style.copyWith(hasBorder: !style.hasBorder)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // ─── TEXT COLOR ───
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
                  // ─── BACKGROUND COLOR & TRANSPARENCY ───
                  const Text('Background Color',
                      style: TextStyle(fontSize: 11, color: Colors.white54)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _colorCircle(0x00000000, style.bgColorHex, (c) {
                        updateStyle(style.copyWith(bgColorHex: c));
                      }, label: 'None'),
                      _colorCircle(0x80000000, style.bgColorHex, (c) {
                        updateStyle(style.copyWith(bgColorHex: c));
                      }),
                      _colorCircle(0xCC000000, style.bgColorHex, (c) {
                        updateStyle(style.copyWith(bgColorHex: c));
                      }),
                      _colorCircle(0x806C5CE7, style.bgColorHex, (c) {
                        updateStyle(style.copyWith(bgColorHex: c));
                      }),
                      _colorCircle(0x80FF5252, style.bgColorHex, (c) {
                        updateStyle(style.copyWith(bgColorHex: c));
                      }),
                      _colorCircle(0x8000C853, style.bgColorHex, (c) {
                        updateStyle(style.copyWith(bgColorHex: c));
                      }),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Background opacity slider
                  if (style.bgColorHex != 0x00000000) ...[
                    Row(
                      children: [
                        const Text('Opacity',
                            style: TextStyle(fontSize: 10, color: Colors.white38)),
                        Expanded(
                          child: Slider(
                            value: ((style.bgColorHex >> 24) & 0xFF) / 255.0,
                            min: 0.0,
                            max: 1.0,
                            divisions: 20,
                            label: '${(((style.bgColorHex >> 24) & 0xFF) / 255.0 * 100).toInt()}%',
                            onChanged: (v) {
                              final alpha = (v * 255).round();
                              final rgb = style.bgColorHex & 0x00FFFFFF;
                              updateStyle(style.copyWith(bgColorHex: (alpha << 24) | rgb));
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  // ─── TEXT POSITION ───
                  if (!isTitle) ...[
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
      int colorHex, int selectedHex, ValueChanged<int> onTap,
      {String? label}) {
    final isSelected = colorHex == selectedHex;
    final isTransparent = (colorHex >> 24) & 0xFF == 0;
    return GestureDetector(
      onTap: () => onTap(colorHex),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: isTransparent ? Colors.transparent : Color(colorHex),
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? Colors.white : Colors.white24,
            width: isSelected ? 3 : 1,
          ),
        ),
        child: isTransparent
            ? Center(
                child: Icon(Icons.block, size: 16,
                    color: isSelected ? Colors.white : Colors.white38),
              )
            : null,
      ),
    );
  }

  Widget _styleToggleButton({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active
                ? const Color(0xFF6C5CE7).withOpacity(0.2)
                : Colors.white.withOpacity(0.04),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active
                  ? const Color(0xFF6C5CE7)
                  : Colors.white.withOpacity(0.08),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16,
                  color: active ? const Color(0xFF6C5CE7) : Colors.white38),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                  color: active ? const Color(0xFF6C5CE7) : Colors.white54,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVoicePanel(ProjectState project) {
    final hasScript = project.scriptText != null && project.scriptText!.isNotEmpty;
    final hasVoiceover = project.assets.any((a) =>
        a.track == TimelineTrack.audio && a.label.startsWith('Voiceover'));

    return Container(
      color: const Color(0xFF1A1A2A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Generate button
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  onPressed: hasScript && !_isGeneratingTts
                      ? () => _generateTts(project)
                      : null,
                  icon: _isGeneratingTts
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.record_voice_over, size: 16),
                  label: Text(_isGeneratingTts
                      ? 'Generating...'
                      : hasVoiceover
                          ? 'Regenerate Voiceover'
                          : 'Generate Voiceover'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF6C5CE7),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
                if (!hasScript)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Add script text first (use AI Create or Text panel)',
                      style: TextStyle(
                          fontSize: 10, color: Colors.white.withOpacity(0.3)),
                    ),
                  ),
                if (hasVoiceover)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle,
                            size: 14, color: Color(0xFF00C853)),
                        const SizedBox(width: 4),
                        const Text(
                          'Voiceover on timeline',
                          style: TextStyle(
                              fontSize: 11, color: Color(0xFF00C853)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text('Select Voice',
                style: TextStyle(
                    fontSize: 11, color: Colors.white.withOpacity(0.5))),
          ),
          Expanded(
            child: ListView(
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 12),
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

  Future<void> _generateTts(ProjectState project) async {
    if (project.scriptText == null || project.scriptText!.isEmpty) return;

    // Need OpenAI API key for TTS
    final apiService = ref.read(apiKeyServiceProvider);
    final openaiKey = apiService.getNextKey(LlmProvider.openai);
    if (openaiKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('OpenAI API key required for voiceover. Add one in Settings.'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    setState(() => _isGeneratingTts = true);
    try {
      final ipc = ref.read(ipcClientProvider);
      final result = await ipc.send(
        IpcMessage(
          type: MessageType.generateTts,
          payload: {
            'text': project.scriptText!,
            'api_key': openaiKey,
            'voice': project.selectedVoice.name,
          },
        ),
        timeout: const Duration(minutes: 2),
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _importStage = progress.payload['stage'] as String? ?? 'Generating TTS';
              _importPercent = progress.payload['percent'] as int? ?? 0;
            });
          }
        },
      );

      if (result.type == MessageType.error) {
        final error = result.payload['message'] ?? 'TTS generation failed';
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $error'), duration: const Duration(seconds: 3)),
          );
        }
      } else {
        // Success — result payload has audio_path, voice, duration_estimate
        final audioPath = result.payload['audio_path'] as String? ?? '';
        final durationEst = (result.payload['duration_estimate'] as num?)?.toDouble() ?? 0;
        if (audioPath.isNotEmpty) {
          setState(() {
            _ttsAudioPath = audioPath;
          });
          // Remove any existing voiceover assets before adding the new one
          final existing = project.assets
              .where((a) => a.track == TimelineTrack.audio && a.label.startsWith('Voiceover'))
              .toList();
          for (final a in existing) {
            ref.read(projectProvider.notifier).removeAsset(a.id);
          }
          // Add as a real timeline asset
          ref.read(projectProvider.notifier).addAsset(TimelineAsset(
            id: 'tts_${DateTime.now().millisecondsSinceEpoch}',
            track: TimelineTrack.audio,
            label: 'Voiceover (${project.selectedVoice.label})',
            filePath: audioPath,
            durationSec: durationEst,
          ));
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Voiceover generated and added to timeline'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('TTS error: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isGeneratingTts = false);
    }
  }

  // ─── AI Create Panel — inline Fact Shorts add-in ───

  Widget _buildMusicPanel(ProjectState project) {
    return Container(
      color: const Color(0xFF1A1A2A),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Search Royalty-Free Music',
                    style: TextStyle(fontSize: 11, color: Colors.white54)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _musicSearchController,
                        decoration: const InputDecoration(
                          hintText: 'e.g. upbeat, cinematic, lo-fi...',
                          prefixIcon: Icon(Icons.search, size: 18),
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        onSubmitted: (_) => _searchMusic(),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _isSearchingMusic ? null : _searchMusic,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      child: _isSearchingMusic
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Search', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Quick genre chips
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: ['Upbeat', 'Cinematic', 'Lo-Fi', 'Ambient', 'Hip-Hop', 'Acoustic']
                      .map((genre) => ActionChip(
                            label: Text(genre, style: const TextStyle(fontSize: 10)),
                            onPressed: () {
                              _musicSearchController.text = genre.toLowerCase();
                              _searchMusic();
                            },
                            visualDensity: VisualDensity.compact,
                          ))
                      .toList(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _musicResults.isEmpty
                ? Center(
                    child: Text(
                      _isSearchingMusic
                          ? 'Searching...'
                          : 'Search for royalty-free music\nto add as background audio.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.3),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    physics: const ClampingScrollPhysics(),
                    itemCount: _musicResults.length,
                    itemBuilder: (context, index) {
                      final track = _musicResults[index];
                      final title = track['title'] as String? ?? 'Untitled';
                      final artist = track['artist'] as String? ?? 'Unknown';
                      final duration = (track['duration'] as num?)?.toDouble() ?? 0;

                      return Card(
                        color: Colors.white.withOpacity(0.03),
                        child: ListTile(
                          leading: const Icon(Icons.music_note,
                              color: Color(0xFF6C5CE7), size: 20),
                          title: Text(title,
                              style: const TextStyle(fontSize: 12),
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '$artist  ${duration > 0 ? "${duration.toStringAsFixed(0)}s" : ""}',
                            style: TextStyle(
                                fontSize: 10,
                                color: Colors.white.withOpacity(0.4)),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.add_circle_outline,
                                color: Color(0xFF6C5CE7), size: 20),
                            onPressed: () {
                              ref.read(projectProvider.notifier).addAsset(TimelineAsset(
                                id: 'music_${DateTime.now().millisecondsSinceEpoch}_$index',
                                track: TimelineTrack.audio,
                                label: title,
                                url: track['download_url'] as String?,
                                metadata: track,
                                durationSec: duration,
                              ));
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Added "$title" to Audio track'),
                                  duration: const Duration(seconds: 1),
                                ),
                              );
                            },
                          ),
                          dense: true,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _searchMusic() async {
    final query = _musicSearchController.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _isSearchingMusic = true;
      _musicResults = [];
    });
    try {
      final ipc = ref.read(ipcClientProvider);
      final result = await ipc.send(IpcMessage(
        type: MessageType.searchMusic,
        payload: {'query': query, 'limit': 20},
      ));
      if (mounted) {
        setState(() {
          _musicResults = List<Map<String, dynamic>>.from(
              result.payload['results'] ?? []);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Music search error: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSearchingMusic = false);
    }
  }

  Widget _buildAiCreatePanel(ProjectState project) {
    return ScriptGeneratorPanel(
      onFactSelected: (fact) {
        // Feed the generated script into the project state — same as if
        // the user had typed it manually. This populates the timeline,
        // preview, and all other panels.
        final notifier = ref.read(projectProvider.notifier);
        notifier.setScript(title: fact.title, text: fact.script);

        // Auto-search stock footage for the visual keywords
        if (fact.visualKeywords.isNotEmpty) {
          _stockSearchController.text = fact.visualKeywords.first;
          _searchStockFootage();
        }

        // Show a confirmation
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Script loaded: ${fact.title}'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      },
      onClose: () => setState(() => _rightPanel = _RightPanel.none),
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

enum _RightPanel { none, stockFootage, textEditor, voicePicker, layers, assetProperties, aiCreate, music }

enum _SelectedTextElement { none, title, body }

enum _EditorTool { select, razor, hand }

/// Menu action item for the desktop-style menu bar.
class _MenuAction {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final String? shortcut;
  final bool isSeparator;

  _MenuAction(this.label, this.icon, this.onTap, {this.shortcut})
      : isSeparator = false;

  _MenuAction.separator()
      : label = '',
        icon = null,
        onTap = null,
        shortcut = null,
        isSeparator = true;
}

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
