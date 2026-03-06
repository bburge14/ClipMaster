import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/ipc/ipc_client.dart';
import '../../../core/ipc/ipc_message.dart';
import '../../../core/services/api_key_service.dart';
import '../../../core/services/project_state.dart';

const _categories = ['Space', 'History', 'Science', 'Technology', 'Nature'];

/// Resolve a font family name to a Google Fonts TextStyle.
TextStyle _googleFont(String family, {double? fontSize, FontWeight? fontWeight,
    FontStyle? fontStyle, Color? color, List<Shadow>? shadows, double? height}) {
  final getter = <String, TextStyle Function({
    TextStyle? textStyle, Color? color, Color? backgroundColor,
    double? fontSize, FontWeight? fontWeight, FontStyle? fontStyle,
    double? letterSpacing, double? wordSpacing, TextBaseline? textBaseline,
    double? height, Locale? locale, Paint? foreground, Paint? background,
    List<Shadow>? shadows, List<FontFeature>? fontFeatures,
    TextDecoration? decoration, Color? decorationColor,
    TextDecorationStyle? decorationStyle, double? decorationThickness,
  })>{
    'Inter': GoogleFonts.inter,
    'Roboto': GoogleFonts.roboto,
    'Montserrat': GoogleFonts.montserrat,
    'Oswald': GoogleFonts.oswald,
    'Lato': GoogleFonts.lato,
    'Poppins': GoogleFonts.poppins,
  };
  final fn = getter[family] ?? GoogleFonts.inter;
  return fn(
    fontSize: fontSize,
    fontWeight: fontWeight,
    fontStyle: fontStyle,
    color: color,
    shadows: shadows,
    height: height,
  );
}

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
  int? _selectedFactIndex;
  String? _error;

  // Multi-model fact generation: provider → list of facts
  final Map<LlmProvider, List<Map<String, dynamic>>> _modelFacts = {};
  final Map<LlmProvider, bool> _modelLoading = {};
  final Map<LlmProvider, String?> _modelErrors = {};
  // Which providers to use (user toggles in left panel)
  final Set<LlmProvider> _enabledProviders = {
    LlmProvider.openai,
    LlmProvider.claude,
    LlmProvider.gemini,
  };

  // Flattened selected fact (from any model)
  LlmProvider? _selectedFactProvider;

  // ── Composer state (active when a fact is selected) ──
  String _composerTitle = '';
  String _composerScript = '';
  List<String> _visualKeywords = [];
  TtsVoice _selectedVoice = TtsVoice.onyx;

  // Text editing
  bool _editingScript = false;
  final _scriptEditController = TextEditingController();

  // Voice preview
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
  final _bgSearchController = TextEditingController(); // manual search

  // ── UNIFIED PLAYBACK STATE ──
  // Single source of truth for timeline position, duration, and playing state.
  // All players (bg, preview, voice) report through _syncPlayback().
  double _scrubPosition = 0.0;        // normalized 0.0–1.0
  double _estimatedDuration = 30.0;   // seconds
  bool _isPlaying = false;
  bool _userScrubbing = false;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _playingSub;

  // NLE timeline panel
  double _timelinePanelHeight = 240.0;
  static const double _minTimelineHeight = 120.0;
  static const double _maxTimelineHeight = 500.0;
  double _timelineZoom = 1.0;
  final ScrollController _timelineHScroll = ScrollController();
  String? _selectedTrackClip; // id of selected clip on the timeline

  // Rendering
  bool _isRendering = false;

  // ── TITLE styling (fully independent) ──
  String _titleFontFamily = 'Inter';
  double _titleFontSize = 48; // in 1080p pixels
  int _titleColorHex = 0xFFFFFFFF;
  bool _titleShadow = true;
  bool _titleBold = false;
  bool _titleItalic = false;
  String _titleAlign = 'center'; // left, center, right
  bool _titleBgEnabled = false;
  int _titleBgColorHex = 0xFF000000; // solid color (RGB)
  double _titleBgOpacity = 0.5;      // separate opacity slider

  // ── BODY styling (fully independent) ──
  String _bodyFontFamily = 'Inter';
  double _bodyFontSize = 40; // in 1080p pixels
  int _bodyColorHex = 0xFFFFFFFF;
  bool _bodyShadow = true;
  bool _bodyBold = false;
  bool _bodyItalic = false;
  String _bodyAlign = 'center'; // left, center, right
  bool _bodyBgEnabled = false;
  int _bodyBgColorHex = 0xFF000000; // solid color (RGB)
  double _bodyBgOpacity = 0.5;      // separate opacity slider

  // Preview mode toggle
  bool _livePreviewMode = false;

  // Active properties section (for click-to-edit on preview)
  String _activePropertiesSection = 'title'; // 'title', 'body', 'voice', 'bg', 'audio'

  // Custom prompt
  String _customPrompt = '';
  final _customPromptController = TextEditingController();

  // Title position (draggable independently)
  double _titlePosX = 0.5;
  double _titlePosY = 0.08;

  // Body text position + box size
  double _textPosX = 0.5;
  double _textPosY = 0.75;
  double _textBoxW = 0.85;
  double _textBoxH = 0.35;

  // ── Text slideshow: split body into sequential slides ──
  bool _slideshowEnabled = false;
  int _wordsPerSlide = 15;

  // ── Background music / sound clips ──
  String? _bgMusicPath;
  String? _bgMusicLabel;
  double _bgMusicVolume = 0.15;

  // Royalty-free audio presets
  static const _royaltyFreeAudio = [
    {'label': 'Ambient Chill', 'path': 'bundled_audio/ambient_chill.mp3'},
    {'label': 'Cinematic Rise', 'path': 'bundled_audio/cinematic_rise.mp3'},
    {'label': 'Lo-fi Beat', 'path': 'bundled_audio/lofi_beat.mp3'},
    {'label': 'Epic Drums', 'path': 'bundled_audio/epic_drums.mp3'},
    {'label': 'Soft Piano', 'path': 'bundled_audio/soft_piano.mp3'},
    {'label': 'News Intro', 'path': 'bundled_audio/news_intro.mp3'},
  ];

  /// Convert ARGB int to FFmpeg hex (strip alpha).
  static String toFfmpegHex(int argb) {
    final rgb = argb & 0x00FFFFFF;
    return '0x${rgb.toRadixString(16).padLeft(6, '0')}';
  }

  /// Convert ARGB int to FFmpeg color@opacity format.
  static String toFfmpegBgColor(int hex) {
    final a = ((hex >> 24) & 0xFF) / 255.0;
    final r = (hex >> 16) & 0xFF;
    final g = (hex >> 8) & 0xFF;
    final b = hex & 0xFF;
    return '0x${r.toRadixString(16).padLeft(2, '0')}'
        '${g.toRadixString(16).padLeft(2, '0')}'
        '${b.toRadixString(16).padLeft(2, '0')}'
        '@${a.toStringAsFixed(2)}';
  }

  /// Combine a solid color hex with a separate opacity value.
  static int _bgWithOpacity(int colorHex, double opacity) {
    return ((opacity * 255).round() << 24) | (colorHex & 0x00FFFFFF);
  }

  /// The ONE active player at any moment.
  Player? get _activePlayer =>
      _livePreviewMode ? (_previewPlayer ?? _bgPlayer) : _bgPlayer;

  /// Seek the active player to a normalized position (0.0–1.0).
  void _seekActivePlayer(double pos) {
    final player = _activePlayer;
    if (player == null) return;
    final dur = player.state.duration;
    if (dur.inMilliseconds > 0) {
      player.seek(Duration(
        milliseconds: (pos * dur.inMilliseconds).round(),
      ));
    }
  }

  /// SINGLE method to wire position/duration/playing streams from any player.
  /// Call this whenever the active player changes (bg loaded, preview loaded,
  /// mode toggle). Cancels old subscriptions before attaching new ones.
  void _syncPlayback(Player player) {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();

    _positionSub = player.stream.position.listen((pos) {
      if (!mounted || _userScrubbing) return;
      final dur = player.state.duration;
      if (dur.inMilliseconds > 0) {
        setState(() {
          _scrubPosition =
              (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
        });
      }
    });
    _durationSub = player.stream.duration.listen((dur) {
      if (!mounted) return;
      if (dur.inSeconds > 0) {
        setState(() => _estimatedDuration = dur.inSeconds.toDouble());
      }
    });
    _playingSub = player.stream.playing.listen((playing) {
      if (!mounted) return;
      setState(() => _isPlaying = playing);
    });
  }

  /// setState + refresh. Only triggers FFmpeg clip if in live preview mode.
  void _setStyleAndRefresh(VoidCallback fn) {
    setState(fn);
    if (_livePreviewMode) _requestPreviewClip();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _previewClipDebounce?.cancel();
    _scriptEditController.dispose();
    _bgSearchController.dispose();
    _customPromptController.dispose();
    _propertiesScrollController.dispose();
    _timelineHScroll.dispose();
    _previewPlayer?.dispose();
    _bgPlayer?.dispose();
    super.dispose();
  }

  // ════════════════════════════════════════════════════════════════
  //  FACT GENERATION
  // ════════════════════════════════════════════════════════════════

  /// Generate facts from all enabled providers in parallel.
  Future<void> _generate() async {
    final apiKeyService = ref.read(apiKeyServiceProvider);

    // Find which providers have keys AND are enabled
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

    // Fire requests in parallel
    final futures = <Future<void>>[];
    for (final entry in toGenerate.entries) {
      futures.add(_generateForProvider(ipc, entry.key, entry.value, customPrompt: _customPrompt));
    }
    await Future.wait(futures);

    if (mounted) {
      setState(() => _isGenerating = false);
    }
  }

  Future<void> _generateForProvider(
      IpcClient ipc, LlmProvider provider, String apiKey,
      {String customPrompt = ''}) async {
    try {
      final response = await ipc.send(
        IpcMessage(
          type: MessageType.generateFacts,
          payload: {
            'category': _selectedCategory.toLowerCase(),
            'count': _factCount,
            'provider': provider.name,
            'api_key': apiKey,
            if (customPrompt.isNotEmpty) 'custom_prompt': customPrompt,
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

  /// Get all facts from all models, flattened.
  List<Map<String, dynamic>> get _allFacts {
    return _modelFacts.values.expand((list) => list).toList();
  }

  void _selectFact(int index, {LlmProvider? provider}) {
    // Get facts from the specific provider, or fall back to all
    List<Map<String, dynamic>> facts;
    if (provider != null && _modelFacts.containsKey(provider)) {
      facts = _modelFacts[provider]!;
    } else {
      facts = _allFacts;
    }
    if (index < 0 || index >= facts.length) return;
    final fact = facts[index];

    setState(() {
      _selectedFactIndex = index;
      _selectedFactProvider = provider;
      _composerTitle = fact['title'] as String? ?? 'Untitled';
      _composerScript = fact['fact'] as String? ?? '';
      _visualKeywords =
          (fact['visual_keywords'] as List<dynamic>?)?.cast<String>() ?? [];
      _editingScript = false;
      _scrubPosition = 0;
      _estimatedDuration =
          (_composerScript.split(' ').length / 2.5).clamp(10, 90);
    });

    // Auto-search for background footage using first visual keyword
    if (_visualKeywords.isNotEmpty) {
      _searchBackgrounds(_visualKeywords.first);
    }

    // Request a true WYSIWYG preview snapshot
    _requestPreviewClip();
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

      // Pause the active video player during voice preview
      _activePlayer?.pause();

      // Play voice through a temporary player, tracking completion
      final voicePlayer = Player();
      voicePlayer.open(Media(audioPath));
      voicePlayer.stream.completed.listen((completed) {
        if (completed && mounted) {
          voicePlayer.dispose();
          // Resume the active video player
          _activePlayer?.play();
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
      _bgVideoLocalPath = null;
      setState(() {});
      return;
    }

    final clip = _selectedBackgrounds[_activeBgIndex];
    // Use download_url for actual video playback, fall back to preview_url
    final videoUrl = clip['download_url'] as String? ?? '';
    final fallbackUrl = clip['preview_url'] as String? ?? '';
    final urlToPlay = videoUrl.isNotEmpty ? videoUrl : fallbackUrl;
    if (urlToPlay.isNotEmpty) {
      _bgPlayer?.dispose();
      _bgPlayer = Player();
      _bgController = VideoController(_bgPlayer!);
      _bgPlayer!.open(Media(urlToPlay));
      _bgPlayer!.setPlaylistMode(PlaylistMode.loop);
      _bgPlayer!.setVolume(0);
      // Wire to unified playback state
      _syncPlayback(_bgPlayer!);
      setState(() => _isPlaying = true);
    }

    // Cache bg video locally for FFmpeg preview clip, then refresh
    _cacheBgVideoLocally().then((_) => _requestPreviewClip());
  }

  // ════════════════════════════════════════════════════════════════
  //  RENDER / EXPORT
  // ════════════════════════════════════════════════════════════════

  Future<void> _renderShort() async {
    if (_composerScript.isEmpty) return;

    // Ask user for video name before rendering
    final nameController = TextEditingController(
      text: _composerTitle.isNotEmpty
          ? _composerTitle.replaceAll(RegExp(r'[^\w\s-]'), '').trim()
          : 'Untitled Short',
    );
    final videoName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Name Your Video',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: nameController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Enter video name...',
            hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white.withOpacity(0.2)),
            ),
            focusedBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF6C5CE7)),
            ),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel',
                style: TextStyle(color: Colors.white.withOpacity(0.5))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, nameController.text),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6C5CE7),
            ),
            child: const Text('Render'),
          ),
        ],
      ),
    );
    nameController.dispose();
    if (videoName == null || videoName.trim().isEmpty) return;
    final safeVideoName = videoName.trim().replaceAll(RegExp(r'[^\w\s-]'), '');

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
      '${docsDir.path}${Platform.pathSeparator}ClipMasterPro${Platform.pathSeparator}shorts',
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

      final payload = <String, dynamic>{
        'text': _composerScript,
        'title': _composerTitle,
        'api_key': openaiKey,
        'voice': _selectedVoice.name,
        'output_dir': shortsDir.path,
        'output_name': safeVideoName,
        'visual_keywords': _visualKeywords,
        // Send actual pixel font sizes directly (no re-computation in server)
        'title_font_size_px': _titleFontSize.toInt(),
        'body_font_size_px': _bodyFontSize.toInt(),
        'title_font_family': _titleFontFamily,
        'body_font_family': _bodyFontFamily,
        'title_color': toFfmpegHex(_titleColorHex),
        'body_color': toFfmpegHex(_bodyColorHex),
        'title_shadow': _titleShadow,
        'body_shadow': _bodyShadow,
        'title_bold': _titleBold,
        'title_italic': _titleItalic,
        'body_bold': _bodyBold,
        'body_italic': _bodyItalic,
        'title_align': _titleAlign,
        'body_align': _bodyAlign,
        'title_pos_x': _titlePosX,
        'title_pos_y': _titlePosY,
        'text_pos_y': _textPosY,
        'text_pos_x': _textPosX,
        'text_box_w': _textBoxW,
        'text_box_h': _textBoxH,
        // Text box backgrounds
        'title_bg_enabled': _titleBgEnabled,
        'title_bg_color': toFfmpegBgColor(_bgWithOpacity(_titleBgColorHex, _titleBgOpacity)),
        'body_bg_enabled': _bodyBgEnabled,
        'body_bg_color': toFfmpegBgColor(_bgWithOpacity(_bodyBgColorHex, _bodyBgOpacity)),
        // Category badge
        'category_label': _selectedCategory,
        // Slideshow mode
        'slideshow_enabled': _slideshowEnabled,
        'words_per_slide': _wordsPerSlide,
        // Background music
        if (_bgMusicPath != null) 'bg_music_path': _bgMusicPath,
        'bg_music_volume': _bgMusicVolume,
        // Multiple backgrounds
        'background_video_urls': _selectedBackgrounds
            .map((b) => b['download_url'] as String? ?? '')
            .where((u) => u.isNotEmpty)
            .toList(),
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

  // Resizable left panel width
  double _leftPanelWidth = 300;

  // Whether left AI panel is visible
  bool _showAiPanel = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final maxLeftW = constraints.maxWidth * 0.45;
              final leftW = _leftPanelWidth.clamp(220.0, maxLeftW);
              return Row(
                children: [
                  // ── Left panel: AI search (collapsible) ──
                  if (_showAiPanel)
                    SizedBox(
                      width: leftW,
                      child: _buildFactListPanel(),
                    ),
                  // ── Drag handle for left panel ──
                  if (_showAiPanel)
                    GestureDetector(
                      onHorizontalDragUpdate: (details) {
                        setState(() {
                          _leftPanelWidth =
                              (_leftPanelWidth + details.delta.dx)
                                  .clamp(220.0, maxLeftW);
                        });
                      },
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeColumn,
                        child: Container(
                          width: 6,
                          color: Colors.white.withOpacity(0.04),
                          child: Center(
                            child: Container(
                              width: 2,
                              height: 32,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(1),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  // ── Always show composer ──
                  Expanded(child: _buildComposer()),
                ],
              );
            },
          ),
        ),
        // ── Resizable drag handle for timeline ──
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
        // ── Transport bar ──
        _buildTransportBar(),
        const Divider(height: 1),
        // ── Timeline tracks ──
        SizedBox(
          height: _timelinePanelHeight,
          child: _buildTimelineTracks(),
        ),
      ],
    );
  }

  // ────────────────────────────────────────────────────────────────
  //  LEFT: FACT LIST PANEL
  // ────────────────────────────────────────────────────────────────

  Widget _buildFactListPanel() {
    final apiKeyService = ref.read(apiKeyServiceProvider);

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
                    size: 18, color: Color(0xFF6C5CE7)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('AI Facts',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () => setState(() => _showAiPanel = false),
                  style: IconButton.styleFrom(
                    foregroundColor: Colors.white38,
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(28, 28),
                  ),
                  tooltip: 'Hide AI Panel',
                ),
              ],
            ),
          ),
          // Category chips
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: _categories.map((cat) {
                return ChoiceChip(
                  label: Text(cat, style: const TextStyle(fontSize: 11)),
                  selected: _selectedCategory == cat,
                  onSelected: (_) => _setStyleAndRefresh(() => _selectedCategory = cat),
                  visualDensity: VisualDensity.compact,
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 8),

          // ── Custom Prompt ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _customPromptController,
              maxLines: 2,
              style: const TextStyle(fontSize: 11),
              decoration: InputDecoration(
                hintText: 'Custom prompt (leave empty for default)...',
                hintStyle: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.2)),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
                ),
                suffixIcon: _customPrompt.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 14),
                        onPressed: () => setState(() {
                          _customPrompt = '';
                          _customPromptController.clear();
                        }),
                        tooltip: 'Use default prompt',
                      )
                    : null,
              ),
              onChanged: (v) => setState(() => _customPrompt = v.trim()),
            ),
          ),
          const SizedBox(height: 8),

          // ── AI Model toggles ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [LlmProvider.openai, LlmProvider.claude, LlmProvider.gemini]
                  .map((p) {
                final hasKey = apiKeyService.getNextKey(p) != null;
                final enabled = _enabledProviders.contains(p);
                final label = p == LlmProvider.openai
                    ? 'GPT-4o'
                    : p == LlmProvider.claude
                        ? 'Claude'
                        : 'Gemini';
                return FilterChip(
                  label: Text(label, style: const TextStyle(fontSize: 10)),
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
                      : Icon(Icons.key_off, size: 12,
                          color: Colors.white.withOpacity(0.2)),
                  tooltip: hasKey ? null : 'No API key configured',
                  visualDensity: VisualDensity.compact,
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
                    onPressed: _isGenerating || _isRendering ? null : _generate,
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
          if (_customPrompt.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2),
              child: Text('Using custom prompt',
                  style: TextStyle(fontSize: 9, color: const Color(0xFF6C5CE7).withOpacity(0.6))),
            ),
          const SizedBox(height: 8),
          Divider(height: 1, color: Colors.white.withOpacity(0.06)),
          // Fact list / loading / error / empty
          Expanded(child: _buildFactListContent(true)),
        ],
      ),
    );
  }

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

  Widget _buildFactListContent(bool isCompact) {
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

    // Show facts grouped by model provider
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        for (final provider in _enabledProviders) ...[
          // Provider section header
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
          // Facts from this model
          if (_modelFacts[provider] != null)
            for (var i = 0; i < _modelFacts[provider]!.length; i++)
              _buildFactCard(
                  _modelFacts[provider]![i], i, provider, isCompact),
          if (_modelFacts[provider] == null && _modelLoading[provider] != true)
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

  Widget _buildFactCard(Map<String, dynamic> fact, int index,
      LlmProvider provider, bool isCompact) {
    final title = fact['title'] as String? ?? 'Untitled';
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
      color: isSelected
          ? _providerColor(provider).withOpacity(0.08)
          : null,
      child: InkWell(
        onTap: () => _selectFact(index, provider: provider),
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
                  Clipboard.setData(
                      ClipboardData(text: fact['fact'] as String? ?? ''));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Copied'),
                        duration: Duration(seconds: 1)),
                  );
                },
                style: IconButton.styleFrom(foregroundColor: Colors.white38),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ────────────────────────────────────────────────────────────────
  //  CENTER: COMPOSER
  // ────────────────────────────────────────────────────────────────

  // Resizable panel width for the properties panel
  double _propertiesPanelWidth = 280;

  Widget _buildComposer() {
    return Container(
      color: const Color(0xFF0A0A14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Clamp the properties panel width
          final maxPanelW = constraints.maxWidth * 0.5;
          final panelW = _propertiesPanelWidth.clamp(200.0, maxPanelW);

          return Row(
            children: [
              // ── Center: 9:16 Preview ──
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      // Title bar
                      Row(
                        children: [
                          // Toggle AI panel button
                          IconButton(
                            icon: Icon(
                              _showAiPanel ? Icons.chevron_left : Icons.auto_awesome,
                              size: 18,
                            ),
                            onPressed: () => setState(() => _showAiPanel = !_showAiPanel),
                            style: IconButton.styleFrom(
                              foregroundColor: const Color(0xFF6C5CE7),
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(32, 32),
                            ),
                            tooltip: _showAiPanel ? 'Hide AI Panel' : 'Show AI Panel',
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                // Click title to edit it inline
                                final controller = TextEditingController(text: _composerTitle);
                                showDialog(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    backgroundColor: const Color(0xFF1A1A2E),
                                    title: const Text('Edit Title', style: TextStyle(color: Colors.white, fontSize: 14)),
                                    content: TextField(
                                      controller: controller,
                                      autofocus: true,
                                      style: const TextStyle(color: Colors.white),
                                      onSubmitted: (v) => Navigator.pop(ctx, v),
                                    ),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                                      FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
                                    ],
                                  ),
                                ).then((result) {
                                  controller.dispose();
                                  if (result != null && result is String && result.isNotEmpty) {
                                    _setStyleAndRefresh(() => _composerTitle = result);
                                  }
                                });
                              },
                              child: Text(
                                _composerTitle.isEmpty ? 'Untitled Short' : _composerTitle,
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w700),
                                overflow: TextOverflow.ellipsis,
                              ),
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
                      Expanded(
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(child: _buildPhonePreview()),
                              const SizedBox(height: 6),
                              TextButton.icon(
                                onPressed: () {
                                  if (!_livePreviewMode) {
                                    _requestPreviewClip();
                                  } else if (_bgPlayer != null) {
                                    // Switching back to edit mode — reconnect timeline to _bgPlayer
                                    _syncPlayback(_bgPlayer!);
                                  }
                                  setState(() => _livePreviewMode = !_livePreviewMode);
                                },
                                icon: Icon(
                                  _livePreviewMode ? Icons.edit : Icons.play_circle,
                                  size: 14,
                                ),
                                label: Text(
                                  _livePreviewMode ? 'Edit Mode' : 'Live Preview',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                style: TextButton.styleFrom(
                                  foregroundColor: _livePreviewMode
                                      ? const Color(0xFF6C5CE7)
                                      : Colors.white54,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
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
              // ── Drag handle to resize properties panel ──
              GestureDetector(
                onHorizontalDragUpdate: (details) {
                  setState(() {
                    _propertiesPanelWidth =
                        (_propertiesPanelWidth - details.delta.dx)
                            .clamp(200.0, maxPanelW);
                  });
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: Container(
                    width: 6,
                    color: Colors.white.withOpacity(0.04),
                    child: Center(
                      child: Container(
                        width: 2,
                        height: 32,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // ── Right: Properties panel (resizable) ──
              SizedBox(
                width: panelW,
                child: _buildPropertiesPanel(),
              ),
            ],
          );
        },
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
                // Text box pixel dimensions (for drag handles)
                final boxW = _textBoxW * frameW;
                final boxH = _textBoxH * frameH;
                final boxLeft = (_textPosX * frameW) - (boxW / 2);
                final boxTop = (_textPosY * frameH) - (boxH / 2);

                // Scale factor for edit mode text (270×480 vs 1080×1920)
                const double scale = 0.25;
                final previewTitleSize = (_titleFontSize * scale).clamp(8.0, 30.0);
                final previewBodySize = (_bodyFontSize * scale).clamp(6.0, 20.0);

                // Body text (slideshow-aware)
                String bodyText;
                if (_slideshowEnabled) {
                  final slides = _getSlides();
                  final idx = (_scrubPosition * slides.length).floor().clamp(0, slides.length - 1);
                  bodyText = slides.isNotEmpty ? slides[idx] : _composerScript;
                } else {
                  bodyText = _composerScript;
                }

                // Alignment for edit mode
                TextAlign titleTextAlign = _titleAlign == 'left' ? TextAlign.left
                    : _titleAlign == 'right' ? TextAlign.right : TextAlign.center;
                TextAlign bodyTextAlign = _bodyAlign == 'left' ? TextAlign.left
                    : _bodyAlign == 'right' ? TextAlign.right : TextAlign.center;

                return Stack(
                  fit: StackFit.expand,
                  children: [
                    // ── Layer 1: Video ──
                    if (_livePreviewMode && _previewController != null)
                      Video(
                        controller: _previewController!,
                        controls: NoVideoControls,
                        fit: BoxFit.cover,
                      )
                    else if (_bgController != null)
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


                    // ── Loading indicator for preview clip ──
                    if (_livePreviewMode && _previewClipLoading)
                      Positioned(
                        top: 4, right: 4,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const SizedBox(
                            width: 12, height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFF6C5CE7),
                            ),
                          ),
                        ),
                      ),

                    // ── Title drag zone ──
                    Positioned(
                      top: (_titlePosY * frameH).clamp(0, frameH - 30),
                      left: ((_titlePosX - 0.44) * frameW).clamp(0, frameW * 0.12),
                      right: ((1.0 - _titlePosX - 0.44) * frameW).clamp(0, frameW * 0.12),
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () => setState(() => _activePropertiesSection = 'title'),
                        onPanUpdate: (details) {
                          setState(() {
                            _titlePosX = (_titlePosX + details.delta.dx / frameW)
                                .clamp(0.1, 0.9);
                            _titlePosY = (_titlePosY + details.delta.dy / frameH)
                                .clamp(0.02, 0.5);
                          });
                        },
                        onPanEnd: (_) {
                          if (_livePreviewMode) _requestPreviewClip();
                        },
                        child: _livePreviewMode
                          ? Container(height: 30, color: Colors.transparent)
                          : Container(
                              padding: _titleBgEnabled
                                  ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
                                  : EdgeInsets.zero,
                              decoration: BoxDecoration(
                                color: _titleBgEnabled
                                    ? Color(_bgWithOpacity(_titleBgColorHex, _titleBgOpacity))
                                    : null,
                                border: Border.all(color: const Color(0xFFFFD700).withOpacity(0.4), width: 1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                _composerTitle,
                                textAlign: titleTextAlign,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: _googleFont(
                                  _titleFontFamily,
                                  fontSize: previewTitleSize,
                                  fontWeight: _titleBold ? FontWeight.w800 : FontWeight.w600,
                                  fontStyle: _titleItalic ? FontStyle.italic : null,
                                  color: Color(_titleColorHex),
                                  shadows: _titleShadow
                                      ? [
                                          const Shadow(color: Colors.black, blurRadius: 6),
                                          const Shadow(color: Colors.black, blurRadius: 12),
                                        ]
                                      : null,
                                ),
                              ),
                            ),
                      ),
                    ),

                    // ── Body text drag zone ──
                    Positioned(
                      left: boxLeft.clamp(0, frameW - boxW),
                      top: boxTop.clamp(0, frameH - boxH),
                      width: boxW,
                      height: boxH,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () => setState(() => _activePropertiesSection = 'body'),
                        onPanUpdate: (details) {
                          setState(() {
                            _textPosX = (_textPosX + details.delta.dx / frameW)
                                .clamp(0.1, 0.9);
                            _textPosY = (_textPosY + details.delta.dy / frameH)
                                .clamp(0.1, 0.92);
                          });
                        },
                        onPanEnd: (_) {
                          if (_livePreviewMode) _requestPreviewClip();
                        },
                        child: _livePreviewMode
                          ? Container(color: Colors.transparent)
                          : Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: _bodyBgEnabled
                                    ? Color(_bgWithOpacity(_bodyBgColorHex, _bodyBgOpacity))
                                    : null,
                                border: Border.all(color: const Color(0xFF6C5CE7).withOpacity(0.5), width: 1.5),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                _wrapText(bodyText, boxW - 12, previewBodySize, bold: _bodyBold),
                                textAlign: bodyTextAlign,
                                overflow: TextOverflow.clip,
                                style: _googleFont(
                                  _bodyFontFamily,
                                  fontSize: previewBodySize,
                                  fontWeight: _bodyBold ? FontWeight.w600 : FontWeight.w400,
                                  fontStyle: _bodyItalic ? FontStyle.italic : null,
                                  color: Color(_bodyColorHex),
                                  height: 1.4,
                                  shadows: _bodyShadow
                                      ? [const Shadow(color: Colors.black, blurRadius: 4)]
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
                        onPanEnd: (_) {
                          if (_livePreviewMode) _requestPreviewClip();
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
                    if (_activePlayer != null)
                      Positioned(
                        bottom: 8,
                        left: 8,
                        child: GestureDetector(
                          onTap: () {
                            _activePlayer?.playOrPause();
                          },
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.6),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: Icon(
                              _isPlaying ? Icons.pause : Icons.play_arrow,
                              size: 18,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),

                    // ── Quick position presets for body (right edge) ──
                    Positioned(
                      right: 4,
                      top: frameH * 0.25,
                      child: Column(
                        children: [
                          _previewPosButton(Icons.vertical_align_top, 0.3),
                          _previewPosButton(Icons.vertical_align_center, 0.5),
                          _previewPosButton(Icons.vertical_align_bottom, 0.78),
                          const SizedBox(height: 8),
                          // Center snap (horiz + vert)
                          GestureDetector(
                            onTap: () => _setStyleAndRefresh(() {
                              _textPosX = 0.5;
                              _textPosY = 0.5;
                            }),
                            child: Container(
                              width: 22, height: 22,
                              margin: const EdgeInsets.only(bottom: 2),
                              decoration: BoxDecoration(
                                color: (_textPosX - 0.5).abs() < 0.02 && (_textPosY - 0.5).abs() < 0.08
                                    ? const Color(0xFF6C5CE7).withOpacity(0.6)
                                    : Colors.black38,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Icon(Icons.center_focus_strong,
                                  size: 14,
                                  color: (_textPosX - 0.5).abs() < 0.02 && (_textPosY - 0.5).abs() < 0.08
                                      ? Colors.white : Colors.white38),
                            ),
                          ),
                          // Center horizontally only
                          GestureDetector(
                            onTap: () => _setStyleAndRefresh(() => _textPosX = 0.5),
                            child: Container(
                              width: 22, height: 22,
                              margin: const EdgeInsets.only(bottom: 2),
                              decoration: BoxDecoration(
                                color: (_textPosX - 0.5).abs() < 0.02
                                    ? const Color(0xFF6C5CE7).withOpacity(0.4)
                                    : Colors.black38,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Icon(Icons.align_horizontal_center,
                                  size: 14,
                                  color: (_textPosX - 0.5).abs() < 0.02
                                      ? Colors.white : Colors.white38),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // ── Mode badge ──
                    Positioned(
                      top: 4, left: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _livePreviewMode ? 'Live Preview' : 'Edit Mode',
                          style: TextStyle(
                            fontSize: 8,
                            fontWeight: FontWeight.w600,
                            color: _livePreviewMode
                                ? const Color(0xFF00E676)
                                : const Color(0xFF6C5CE7),
                          ),
                        ),
                      ),
                    ),

                    // ── Drag hint ──
                    Positioned(
                      bottom: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'Tap text to edit settings',
                          style: TextStyle(
                              fontSize: 8,
                              color: Colors.white.withOpacity(0.4)),
                        ),
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

  // ── Live preview clip (FFmpeg-rendered video) ──
  Player? _previewPlayer;
  VideoController? _previewController;
  bool _previewClipLoading = false;
  Timer? _previewClipDebounce;
  String? _bgVideoLocalPath; // cached bg video for server-side rendering

  /// Request a preview video clip from the sidecar (FFmpeg-rendered 5-sec MP4).
  /// This uses the EXACT same drawtext filters as the final render.
  void _requestPreviewClip() {
    _previewClipDebounce?.cancel();
    _previewClipDebounce = Timer(const Duration(milliseconds: 500), () async {
      if (!mounted) return;
      if (_composerTitle.isEmpty && _composerScript.isEmpty) return;

      setState(() => _previewClipLoading = true);
      try {
        final ipc = ref.read(ipcClientProvider);
        final response = await ipc.send(
          IpcMessage(
            type: MessageType.previewVideoClip,
            payload: {
              'title': _composerTitle,
              'text': _composerScript,
              'title_font_size_px': _titleFontSize.toInt(),
              'body_font_size_px': _bodyFontSize.toInt(),
              'title_font_family': _titleFontFamily,
              'body_font_family': _bodyFontFamily,
              'title_color': toFfmpegHex(_titleColorHex),
              'body_color': toFfmpegHex(_bodyColorHex),
              'title_shadow': _titleShadow,
              'body_shadow': _bodyShadow,
              'title_bold': _titleBold,
              'title_italic': _titleItalic,
              'body_bold': _bodyBold,
              'body_italic': _bodyItalic,
              'title_align': _titleAlign,
              'body_align': _bodyAlign,
              'title_pos_x': _titlePosX,
              'title_pos_y': _titlePosY,
              'text_pos_x': _textPosX,
              'text_pos_y': _textPosY,
              'text_box_w': _textBoxW,
              'text_box_h': _textBoxH,
              'title_bg_enabled': _titleBgEnabled,
              'title_bg_color': toFfmpegBgColor(_bgWithOpacity(_titleBgColorHex, _titleBgOpacity)),
              'body_bg_enabled': _bodyBgEnabled,
              'body_bg_color': toFfmpegBgColor(_bgWithOpacity(_bodyBgColorHex, _bodyBgOpacity)),
              'category_label': _selectedCategory,
              'slideshow_enabled': _slideshowEnabled,
              'words_per_slide': _wordsPerSlide,
              if (_bgVideoLocalPath != null)
                'bg_video_local_path': _bgVideoLocalPath,
              if (_previewAudioPath != null)
                'tts_audio_path': _previewAudioPath,
            },
          ),
          timeout: const Duration(seconds: 30),
        );
        if (mounted && response.type == MessageType.result) {
          final clipPath = response.payload['clip_path'] as String?;
          if (clipPath != null && File(clipPath).existsSync()) {
            _loadPreviewClip(clipPath);
            return;
          }
        }
      } catch (e) {
        // Preview clip is best-effort — don't block the UI
      }
      if (mounted) setState(() => _previewClipLoading = false);
    });
  }

  /// Load the FFmpeg-rendered preview clip into the dedicated preview player.
  void _loadPreviewClip(String clipPath) {
    if (_previewPlayer == null) {
      _previewPlayer = Player();
      _previewController = VideoController(_previewPlayer!);
    }
    _previewPlayer!.open(Media(clipPath));
    _previewPlayer!.setPlaylistMode(PlaylistMode.loop);
    _previewPlayer!.setVolume(100);

    // Wire to unified playback state
    _syncPlayback(_previewPlayer!);

    if (mounted) setState(() => _previewClipLoading = false);
  }

  /// Download the active bg video to a local temp file for FFmpeg snapshot.
  Future<void> _cacheBgVideoLocally() async {
    if (_selectedBackgrounds.isEmpty) {
      _bgVideoLocalPath = null;
      return;
    }
    final clip = _selectedBackgrounds[_activeBgIndex];
    final videoUrl = clip['download_url'] as String? ?? '';
    if (videoUrl.isEmpty) return;

    try {
      final dir = await getTemporaryDirectory();
      final localPath = '${dir.path}/cm_preview_bg.mp4';
      final resp = await http.get(Uri.parse(videoUrl));
      if (resp.statusCode == 200) {
        await File(localPath).writeAsBytes(resp.bodyBytes);
        _bgVideoLocalPath = localPath;
      }
    } catch (_) {
      // Non-fatal
    }
  }

  /// Split body text into slideshow slides (each with _wordsPerSlide words).
  List<String> _getSlides() {
    final words = _composerScript.split(' ');
    if (words.isEmpty) return [_composerScript];
    final slides = <String>[];
    for (var i = 0; i < words.length; i += _wordsPerSlide) {
      final end = (i + _wordsPerSlide).clamp(0, words.length);
      slides.add(words.sublist(i, end).join(' '));
    }
    return slides;
  }

  /// Word-wrap text identically to the Python server's _wrap_text().
  /// This ensures the preview shows the same line breaks as the render.
  String _wrapText(String text, double boxWidthPx, double fontSizePx, {bool bold = false}) {
    final avgCharW = fontSizePx * (bold ? 0.60 : 0.52);
    final charsPerLine = (boxWidthPx / avgCharW).floor().clamp(15, 200);
    final words = text.split(' ');
    final lines = <String>[];
    var currentLine = '';
    for (final word in words) {
      if (currentLine.length + word.length + 1 > charsPerLine &&
          currentLine.isNotEmpty) {
        lines.add(currentLine);
        currentLine = word;
      } else {
        currentLine = currentLine.isEmpty ? word : '$currentLine $word';
      }
    }
    if (currentLine.isNotEmpty) lines.add(currentLine);
    return lines.join('\n');
  }

  Widget _previewPosButton(IconData icon, double y) {
    final isActive = (_textPosY - y).abs() < 0.08;
    return GestureDetector(
      onTap: () => _setStyleAndRefresh(() => _textPosY = y),
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

  final _propertiesScrollController = ScrollController();

  /// Apply a layout preset — auto-configures title, body position, sizing, and style.
  void _applyPreset(_LayoutPreset preset) {
    _setStyleAndRefresh(() {
      _titleFontFamily = preset.titleFont;
      _titleFontSize = preset.titleSize;
      _titleBold = preset.titleBold;
      _titleItalic = false;
      _titleAlign = preset.titleAlign;
      _titleColorHex = preset.titleColor;
      _titleShadow = preset.titleShadow;
      _titleBgEnabled = preset.titleBgEnabled;
      _titleBgColorHex = preset.titleBgColor;
      _titleBgOpacity = preset.titleBgOpacity;
      _titlePosX = preset.titlePosX;
      _titlePosY = preset.titlePosY;
      _bodyFontFamily = preset.bodyFont;
      _bodyFontSize = preset.bodySize;
      _bodyBold = preset.bodyBold;
      _bodyItalic = false;
      _bodyAlign = preset.bodyAlign;
      _bodyColorHex = preset.bodyColor;
      _bodyShadow = preset.bodyShadow;
      _bodyBgEnabled = preset.bodyBgEnabled;
      _bodyBgColorHex = preset.bodyBgColor;
      _bodyBgOpacity = preset.bodyBgOpacity;
      _textPosX = preset.bodyPosX;
      _textPosY = preset.bodyPosY;
      _textBoxW = preset.bodyBoxW;
      _textBoxH = preset.bodyBoxH;
    });
  }

  Widget _buildPropertiesPanel() {
    return Container(
      color: const Color(0xFF141420),
      child: ListView(
        controller: _propertiesScrollController,
        padding: const EdgeInsets.all(12),
        children: [
          // ══════════════════════════════════════
          // ── QUICK SETUP PRESETS ──
          // ══════════════════════════════════════
          _sectionHeader('Quick Setup', Icons.auto_fix_high),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _applyPreset(_LayoutPreset.standard),
              icon: const Icon(Icons.auto_awesome, size: 16),
              label: const Text('Auto Setup', style: TextStyle(fontSize: 12)),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF6C5CE7),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _LayoutPreset.all.map((preset) {
              return ActionChip(
                avatar: Icon(preset.icon, size: 14, color: preset.accentColor),
                label: Text(preset.name, style: const TextStyle(fontSize: 10)),
                onPressed: () => _applyPreset(preset),
                backgroundColor: preset.accentColor.withOpacity(0.1),
                side: BorderSide(color: preset.accentColor.withOpacity(0.2)),
                visualDensity: VisualDensity.compact,
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          Divider(color: Colors.white.withOpacity(0.06)),
          const SizedBox(height: 12),

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

          // ══════════════════════════════════════
          // ── TITLE STYLE (fully independent) ──
          // ══════════════════════════════════════
          _sectionHeader('Title Style', Icons.title),
          const SizedBox(height: 8),
          // Font family
          DropdownButton<String>(
            value: _titleFontFamily,
            isExpanded: true,
            items: ['Inter', 'Roboto', 'Montserrat', 'Oswald', 'Lato', 'Poppins']
                .map((f) => DropdownMenuItem(
                    value: f,
                    child: Text(f, style: const TextStyle(fontSize: 12))))
                .toList(),
            onChanged: (v) {
              if (v != null) _setStyleAndRefresh(() => _titleFontFamily = v);
            },
          ),
          // Bold / Italic / Alignment
          const SizedBox(height: 4),
          Row(
            children: [
              _formatToggle('B', _titleBold,
                  (v) => _setStyleAndRefresh(() => _titleBold = v)),
              const SizedBox(width: 6),
              _formatToggle('I', _titleItalic,
                  (v) => _setStyleAndRefresh(() => _titleItalic = v),
                  italic: true),
              const SizedBox(width: 12),
              _alignButton(Icons.format_align_left, 'left', _titleAlign,
                  (v) => _setStyleAndRefresh(() => _titleAlign = v)),
              _alignButton(Icons.format_align_center, 'center', _titleAlign,
                  (v) => _setStyleAndRefresh(() => _titleAlign = v)),
              _alignButton(Icons.format_align_right, 'right', _titleAlign,
                  (v) => _setStyleAndRefresh(() => _titleAlign = v)),
            ],
          ),
          // Font size (in 1080p pixels, preview scales down)
          const SizedBox(height: 4),
          Text('Size: ${_titleFontSize.toInt()}px',
              style: TextStyle(
                  fontSize: 10, color: Colors.white.withOpacity(0.4))),
          Slider(
            value: _titleFontSize,
            min: 24,
            max: 96,
            divisions: 18,
            onChanged: (v) => _setStyleAndRefresh(() => _titleFontSize = v),
          ),
          // Color
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _colorDotFor(0xFFFFFFFF, _titleColorHex,
                  (c) => _setStyleAndRefresh(() => _titleColorHex = c)),
              _colorDotFor(0xFFFFD700, _titleColorHex,
                  (c) => _setStyleAndRefresh(() => _titleColorHex = c)),
              _colorDotFor(0xFF6C5CE7, _titleColorHex,
                  (c) => _setStyleAndRefresh(() => _titleColorHex = c)),
              _colorDotFor(0xFF00C853, _titleColorHex,
                  (c) => _setStyleAndRefresh(() => _titleColorHex = c)),
              _colorDotFor(0xFFFF5252, _titleColorHex,
                  (c) => _setStyleAndRefresh(() => _titleColorHex = c)),
              _colorDotFor(0xFF40C4FF, _titleColorHex,
                  (c) => _setStyleAndRefresh(() => _titleColorHex = c)),
            ],
          ),
          const SizedBox(height: 6),
          // Shadow toggle
          Row(
            children: [
              Text('Shadow',
                  style: TextStyle(
                      fontSize: 11, color: Colors.white.withOpacity(0.5))),
              const Spacer(),
              Switch(
                value: _titleShadow,
                onChanged: (v) => _setStyleAndRefresh(() => _titleShadow = v),
              ),
            ],
          ),
          // Background
          Row(
            children: [
              Text('Background',
                  style: TextStyle(
                      fontSize: 11, color: Colors.white.withOpacity(0.5))),
              const Spacer(),
              Switch(
                value: _titleBgEnabled,
                onChanged: (v) => _setStyleAndRefresh(() => _titleBgEnabled = v),
              ),
            ],
          ),
          if (_titleBgEnabled) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _colorDotFor(0xFF000000, _titleBgColorHex,
                    (c) => _setStyleAndRefresh(() => _titleBgColorHex = c)),
                _colorDotFor(0xFF6C5CE7, _titleBgColorHex,
                    (c) => _setStyleAndRefresh(() => _titleBgColorHex = c)),
                _colorDotFor(0xFFFF5252, _titleBgColorHex,
                    (c) => _setStyleAndRefresh(() => _titleBgColorHex = c)),
                _colorDotFor(0xFF1A1A2E, _titleBgColorHex,
                    (c) => _setStyleAndRefresh(() => _titleBgColorHex = c)),
              ],
            ),
            const SizedBox(height: 4),
            Text('Opacity: ${(_titleBgOpacity * 100).toInt()}%',
                style: TextStyle(
                    fontSize: 10, color: Colors.white.withOpacity(0.4))),
            Slider(
              value: _titleBgOpacity,
              min: 0.05,
              max: 1.0,
              divisions: 19,
              onChanged: (v) => _setStyleAndRefresh(() => _titleBgOpacity = v),
            ),
          ],
          const SizedBox(height: 8),
          Divider(color: Colors.white.withOpacity(0.06)),
          const SizedBox(height: 8),

          // ══════════════════════════════════════
          // ── BODY STYLE (fully independent) ──
          // ══════════════════════════════════════
          _sectionHeader('Body Style', Icons.text_fields),
          const SizedBox(height: 8),
          // Font family
          DropdownButton<String>(
            value: _bodyFontFamily,
            isExpanded: true,
            items: ['Inter', 'Roboto', 'Montserrat', 'Oswald', 'Lato', 'Poppins']
                .map((f) => DropdownMenuItem(
                    value: f,
                    child: Text(f, style: const TextStyle(fontSize: 12))))
                .toList(),
            onChanged: (v) {
              if (v != null) _setStyleAndRefresh(() => _bodyFontFamily = v);
            },
          ),
          // Bold / Italic / Alignment
          const SizedBox(height: 4),
          Row(
            children: [
              _formatToggle('B', _bodyBold,
                  (v) => _setStyleAndRefresh(() => _bodyBold = v)),
              const SizedBox(width: 6),
              _formatToggle('I', _bodyItalic,
                  (v) => _setStyleAndRefresh(() => _bodyItalic = v),
                  italic: true),
              const SizedBox(width: 12),
              _alignButton(Icons.format_align_left, 'left', _bodyAlign,
                  (v) => _setStyleAndRefresh(() => _bodyAlign = v)),
              _alignButton(Icons.format_align_center, 'center', _bodyAlign,
                  (v) => _setStyleAndRefresh(() => _bodyAlign = v)),
              _alignButton(Icons.format_align_right, 'right', _bodyAlign,
                  (v) => _setStyleAndRefresh(() => _bodyAlign = v)),
            ],
          ),
          // Font size (in 1080p pixels)
          const SizedBox(height: 4),
          Text('Size: ${_bodyFontSize.toInt()}px',
              style: TextStyle(
                  fontSize: 10, color: Colors.white.withOpacity(0.4))),
          Slider(
            value: _bodyFontSize,
            min: 20,
            max: 80,
            divisions: 15,
            onChanged: (v) => _setStyleAndRefresh(() => _bodyFontSize = v),
          ),
          // Color
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _colorDotFor(0xFFFFFFFF, _bodyColorHex,
                  (c) => _setStyleAndRefresh(() => _bodyColorHex = c)),
              _colorDotFor(0xFFFFD700, _bodyColorHex,
                  (c) => _setStyleAndRefresh(() => _bodyColorHex = c)),
              _colorDotFor(0xFF6C5CE7, _bodyColorHex,
                  (c) => _setStyleAndRefresh(() => _bodyColorHex = c)),
              _colorDotFor(0xFF00C853, _bodyColorHex,
                  (c) => _setStyleAndRefresh(() => _bodyColorHex = c)),
              _colorDotFor(0xFFFF5252, _bodyColorHex,
                  (c) => _setStyleAndRefresh(() => _bodyColorHex = c)),
              _colorDotFor(0xFF40C4FF, _bodyColorHex,
                  (c) => _setStyleAndRefresh(() => _bodyColorHex = c)),
            ],
          ),
          const SizedBox(height: 6),
          // Shadow toggle
          Row(
            children: [
              Text('Shadow',
                  style: TextStyle(
                      fontSize: 11, color: Colors.white.withOpacity(0.5))),
              const Spacer(),
              Switch(
                value: _bodyShadow,
                onChanged: (v) => _setStyleAndRefresh(() => _bodyShadow = v),
              ),
            ],
          ),
          // Background
          Row(
            children: [
              Text('Background',
                  style: TextStyle(
                      fontSize: 11, color: Colors.white.withOpacity(0.5))),
              const Spacer(),
              Switch(
                value: _bodyBgEnabled,
                onChanged: (v) => _setStyleAndRefresh(() => _bodyBgEnabled = v),
              ),
            ],
          ),
          if (_bodyBgEnabled) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _colorDotFor(0xFF000000, _bodyBgColorHex,
                    (c) => _setStyleAndRefresh(() => _bodyBgColorHex = c)),
                _colorDotFor(0xFF6C5CE7, _bodyBgColorHex,
                    (c) => _setStyleAndRefresh(() => _bodyBgColorHex = c)),
                _colorDotFor(0xFFFF5252, _bodyBgColorHex,
                    (c) => _setStyleAndRefresh(() => _bodyBgColorHex = c)),
                _colorDotFor(0xFF1A1A2E, _bodyBgColorHex,
                    (c) => _setStyleAndRefresh(() => _bodyBgColorHex = c)),
              ],
            ),
            const SizedBox(height: 4),
            Text('Opacity: ${(_bodyBgOpacity * 100).toInt()}%',
                style: TextStyle(
                    fontSize: 10, color: Colors.white.withOpacity(0.4))),
            Slider(
              value: _bodyBgOpacity,
              min: 0.05,
              max: 1.0,
              divisions: 19,
              onChanged: (v) => _setStyleAndRefresh(() => _bodyBgOpacity = v),
            ),
          ],
          const SizedBox(height: 8),

          // ── Text Box Layout ──
          Text('Text Box Width: ${(_textBoxW * 100).toInt()}%',
              style: TextStyle(
                  fontSize: 10, color: Colors.white.withOpacity(0.4))),
          Slider(
            value: _textBoxW,
            min: 0.3,
            max: 0.95,
            divisions: 13,
            onChanged: (v) => _setStyleAndRefresh(() => _textBoxW = v),
          ),
          Text('Text Box Height: ${(_textBoxH * 100).toInt()}%',
              style: TextStyle(
                  fontSize: 10, color: Colors.white.withOpacity(0.4))),
          Slider(
            value: _textBoxH,
            min: 0.1,
            max: 0.7,
            divisions: 12,
            onChanged: (v) => _setStyleAndRefresh(() => _textBoxH = v),
          ),
          const SizedBox(height: 8),
          Divider(color: Colors.white.withOpacity(0.06)),
          const SizedBox(height: 8),

          // ══════════════════════════════════════
          // ── TEXT SLIDESHOW ──
          // ══════════════════════════════════════
          _sectionHeader('Text Slides', Icons.slideshow),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Split body into sequential slides',
                  style: TextStyle(
                      fontSize: 10, color: Colors.white.withOpacity(0.35)),
                ),
              ),
              Switch(
                value: _slideshowEnabled,
                onChanged: (v) => _setStyleAndRefresh(() => _slideshowEnabled = v),
              ),
            ],
          ),
          if (_slideshowEnabled) ...[
            Text('Words per slide: $_wordsPerSlide',
                style: TextStyle(
                    fontSize: 10, color: Colors.white.withOpacity(0.4))),
            Slider(
              value: _wordsPerSlide.toDouble(),
              min: 5,
              max: 40,
              divisions: 7,
              onChanged: (v) =>
                  _setStyleAndRefresh(() => _wordsPerSlide = v.toInt()),
            ),
            Text(
              '${_getSlides().length} slides total',
              style: TextStyle(
                  fontSize: 10, color: Colors.white.withOpacity(0.3)),
            ),
          ],
          const SizedBox(height: 8),
          Divider(color: Colors.white.withOpacity(0.06)),
          const SizedBox(height: 8),

          // ══════════════════════════════════════
          // ── AUDIO / SOUND CLIPS ──
          // ══════════════════════════════════════
          _sectionHeader('Audio', Icons.music_note),
          const SizedBox(height: 8),
          if (_bgMusicPath != null) ...[
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.03),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white.withOpacity(0.08)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.audiotrack,
                      size: 14, color: Color(0xFF6C5CE7)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _bgMusicLabel ?? 'Audio clip',
                      style: TextStyle(
                          fontSize: 10,
                          color: Colors.white.withOpacity(0.6)),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => setState(() {
                      _bgMusicPath = null;
                      _bgMusicLabel = null;
                    }),
                    child: Icon(Icons.close,
                        size: 14,
                        color: Colors.white.withOpacity(0.3)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text('Volume: ${(_bgMusicVolume * 100).toInt()}%',
                style: TextStyle(
                    fontSize: 10, color: Colors.white.withOpacity(0.4))),
            Slider(
              value: _bgMusicVolume,
              min: 0.0,
              max: 1.0,
              divisions: 20,
              onChanged: (v) => setState(() => _bgMusicVolume = v),
            ),
          ] else ...[
            // Royalty-free audio presets
            Text('Royalty-Free',
                style: TextStyle(
                    fontSize: 10, color: Colors.white.withOpacity(0.35))),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: _royaltyFreeAudio.map((audio) {
                return ActionChip(
                  label: Text(audio['label']!,
                      style: const TextStyle(fontSize: 9)),
                  onPressed: () {
                    setState(() {
                      _bgMusicPath = audio['path'];
                      _bgMusicLabel = audio['label'];
                    });
                  },
                  avatar: const Icon(Icons.music_note, size: 10),
                  backgroundColor:
                      const Color(0xFF6C5CE7).withOpacity(0.08),
                  side: BorderSide(
                      color: const Color(0xFF6C5CE7).withOpacity(0.15)),
                  visualDensity: VisualDensity.compact,
                );
              }).toList(),
            ),
            const SizedBox(height: 8),
            // Custom audio import
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _pickAudioFile,
                icon: const Icon(Icons.folder_open, size: 14),
                label: const Text('Import Your Own Audio',
                    style: TextStyle(fontSize: 11)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white60,
                  side: BorderSide(color: Colors.white.withOpacity(0.12)),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                ),
              ),
            ),
          ],
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
            'Auto-searched from AI keywords. Tap to add/remove.',
            style: TextStyle(
                fontSize: 9, color: Colors.white.withOpacity(0.25)),
          ),
          const SizedBox(height: 6),
          // ── Manual search bar ──
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _bgSearchController,
                  decoration: InputDecoration(
                    hintText: 'Search videos...',
                    hintStyle: TextStyle(
                        fontSize: 11, color: Colors.white.withOpacity(0.2)),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide:
                            BorderSide(color: Colors.white.withOpacity(0.1))),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide:
                            BorderSide(color: Colors.white.withOpacity(0.08))),
                  ),
                  style: const TextStyle(fontSize: 11),
                  onSubmitted: (v) {
                    if (v.trim().isNotEmpty) _searchBackgrounds(v.trim());
                  },
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.search, size: 16),
                onPressed: () {
                  final q = _bgSearchController.text.trim();
                  if (q.isNotEmpty) _searchBackgrounds(q);
                },
                style: IconButton.styleFrom(
                  foregroundColor: Colors.white54,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(32, 32),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_bgResults.isEmpty && !_isSearchingBg)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _visualKeywords.isEmpty
                      ? 'Search for background videos above'
                      : 'No results yet',
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
                    _setStyleAndRefresh(() {
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

  /// Generic color dot that works with any state variable.
  Widget _formatToggle(String label, bool active, ValueChanged<bool> onChanged,
      {bool italic = false}) {
    return GestureDetector(
      onTap: () => onChanged(!active),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: active ? const Color(0xFF6C5CE7) : Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: active ? Colors.white38 : Colors.white12,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: label == 'B' ? FontWeight.w800 : FontWeight.w400,
            fontStyle: italic ? FontStyle.italic : FontStyle.normal,
            color: active ? Colors.white : Colors.white54,
          ),
        ),
      ),
    );
  }

  Widget _alignButton(IconData icon, String value, String current,
      ValueChanged<String> onChanged) {
    final active = value == current;
    return GestureDetector(
      onTap: () => onChanged(value),
      child: Container(
        width: 28,
        height: 28,
        margin: const EdgeInsets.only(right: 2),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF6C5CE7).withOpacity(0.4) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(icon, size: 16,
            color: active ? Colors.white : Colors.white38),
      ),
    );
  }

  Widget _colorDotFor(int hex, int currentHex, ValueChanged<int> onSelect) {
    final isSelected = hex == currentHex;
    return GestureDetector(
      onTap: () => onSelect(hex),
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: Color(hex),
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? Colors.white : Colors.white24,
            width: isSelected ? 2.5 : 1,
          ),
        ),
      ),
    );
  }

  Future<void> _pickAudioFile() async {
    // Use file_picker or simple path input for audio files
    // For now, use a dialog to enter a file path
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Background Audio'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Enter the full path to an audio file (.mp3, .wav, .ogg)',
              style: TextStyle(
                  fontSize: 12, color: Colors.white.withOpacity(0.5)),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: '/path/to/audio.mp3',
                isDense: true,
              ),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null && result.isNotEmpty) {
      final file = File(result);
      if (await file.exists()) {
        setState(() {
          _bgMusicPath = result;
          _bgMusicLabel = result.split(Platform.pathSeparator).last;
        });
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('File not found.')),
          );
        }
      }
    }
  }

  // ────────────────────────────────────────────────────────────────
  //  BOTTOM: NLE TIMELINE
  // ────────────────────────────────────────────────────────────────

  Widget _buildTransportBar() {
    final player = _activePlayer;
    final dur = player?.state.duration ?? Duration.zero;
    final pos = player?.state.position ?? Duration.zero;

    return Container(
      height: 44,
      color: const Color(0xFF141420),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.skip_previous, size: 18),
            onPressed: () {
              player?.seek(Duration.zero);
              setState(() => _scrubPosition = 0);
            },
            tooltip: 'Go to start',
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: const Icon(Icons.replay_5, size: 18),
            onPressed: () {
              if (player != null) {
                final newPos = pos - const Duration(seconds: 5);
                player.seek(newPos < Duration.zero ? Duration.zero : newPos);
              }
            },
            tooltip: 'Back 5s',
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: Icon(
              _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
              size: 28,
              color: const Color(0xFF6C5CE7),
            ),
            onPressed: () => player?.playOrPause(),
            tooltip: _isPlaying ? 'Pause' : 'Play',
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: const Icon(Icons.forward_5, size: 18),
            onPressed: () {
              if (player != null) {
                final newPos = pos + const Duration(seconds: 5);
                player.seek(newPos > dur ? dur : newPos);
              }
            },
            tooltip: 'Forward 5s',
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: const Icon(Icons.skip_next, size: 18),
            onPressed: () {
              if (player != null && dur > Duration.zero) {
                player.seek(dur);
              }
            },
            tooltip: 'Go to end',
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 6),
          Text(
            '${_formatTime(_scrubPosition * _estimatedDuration)} / ${_formatTime(_estimatedDuration)}',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: Colors.white.withOpacity(0.6),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                activeTrackColor: const Color(0xFF6C5CE7),
                inactiveTrackColor: Colors.white12,
                thumbColor: const Color(0xFF6C5CE7),
              ),
              child: Slider(
                value: _scrubPosition.clamp(0.0, 1.0),
                onChangeStart: (_) => _userScrubbing = true,
                onChanged: (v) {
                  setState(() => _scrubPosition = v);
                  _seekActivePlayer(v);
                },
                onChangeEnd: (_) => _userScrubbing = false,
              ),
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.zoom_in, size: 14, color: Colors.white38),
          SizedBox(
            width: 80,
            child: Slider(
              value: _timelineZoom,
              min: 0.5,
              max: 4.0,
              onChanged: (v) => setState(() => _timelineZoom = v),
            ),
          ),
          Text('${_timelineZoom.toStringAsFixed(1)}x',
              style: const TextStyle(fontSize: 9, color: Colors.white38)),
        ],
      ),
    );
  }

  Widget _buildTimelineTracks() {
    // Caption segments synced with slideshow state
    final captionSlides = _slideshowEnabled
        ? _getSlides()
        : [_composerScript];
    final segmentCount = captionSlides.length.clamp(1, 20);

    final voiceLabel = _previewAudioPath != null
        ? _selectedVoice.label
        : 'TTS (${_selectedVoice.label})';
    final hasVoice = _composerScript.isNotEmpty;
    final hasAudio = _bgMusicPath != null;

    // Build track data
    final tracks = <_NleTrackData>[
      _NleTrackData(
        color: const Color(0xFF2D824A),
        clips: hasVoice
            ? [_NleClipData(id: 'voice', label: voiceLabel, startFrac: 0.0, endFrac: 1.0)]
            : [],
      ),
      _NleTrackData(
        color: const Color(0xFF2D5AA0),
        clips: _selectedBackgrounds.isNotEmpty
            ? _selectedBackgrounds.asMap().entries.map((e) {
                final frac = 1.0 / _selectedBackgrounds.length;
                final desc = e.value['description'] as String? ?? 'Clip ${e.key + 1}';
                return _NleClipData(
                  id: 'video_${e.key}',
                  label: desc.length > 20 ? desc.substring(0, 20) : desc,
                  startFrac: e.key * frac,
                  endFrac: (e.key + 1) * frac,
                );
              }).toList()
            : [_NleClipData(id: 'video_bg', label: 'Gradient background', startFrac: 0.0, endFrac: 1.0)],
      ),
      _NleTrackData(
        color: const Color(0xFF6C5CE7),
        clips: hasAudio
            ? [_NleClipData(id: 'audio', label: _bgMusicLabel ?? 'Audio', startFrac: 0.0, endFrac: 1.0)]
            : [],
      ),
      _NleTrackData(
        color: const Color(0xFF82782D),
        clips: List.generate(segmentCount, (i) {
          final frac = 1.0 / segmentCount;
          final slideText = i < captionSlides.length ? captionSlides[i] : '';
          final label = slideText.length > 25
              ? '${slideText.substring(0, 25)}...'
              : slideText.isNotEmpty ? slideText : 'Slide ${i + 1}';
          return _NleClipData(
            id: 'caption_$i',
            label: label,
            startFrac: i * frac,
            endFrac: (i + 1) * frac,
          );
        }),
      ),
    ];

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
                      _buildNleTrackLabel('Voice', Icons.record_voice_over, const Color(0xFF2D824A)),
                      _buildNleTrackLabel('Video', Icons.videocam, const Color(0xFF2D5AA0)),
                      _buildNleTrackLabel('Audio', Icons.music_note, const Color(0xFF6C5CE7)),
                      _buildNleTrackLabel('Text', Icons.text_fields, const Color(0xFF82782D)),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                // Scrollable track area (ruler + tracks scroll together)
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, outerConstraints) {
                      final viewWidth = outerConstraints.maxWidth > 0 ? outerConstraints.maxWidth : 800.0;
                      final contentWidth = (viewWidth * _timelineZoom).clamp(viewWidth, viewWidth * 4.0);

                      return SingleChildScrollView(
                        controller: _timelineHScroll,
                        scrollDirection: Axis.horizontal,
                        physics: const ClampingScrollPhysics(),
                        child: SizedBox(
                          width: contentWidth,
                          child: Column(
                            children: [
                              // Time ruler (scrolls with tracks)
                              _buildTimeRuler(contentWidth),
                              const Divider(height: 1, color: Colors.white10),
                              // Track rows
                              Expanded(
                                child: _TimelineTrackArea(
                                  totalWidth: contentWidth,
                                  scrubPosition: _scrubPosition,
                                  estimatedDuration: _estimatedDuration,
                                  onScrub: (pos) {
                                    _userScrubbing = true;
                                    setState(() => _scrubPosition = pos);
                                    _seekActivePlayer(pos);
                                  },
                                  onScrubEnd: () => _userScrubbing = false,
                                  selectedClipId: _selectedTrackClip,
                                  onClipSelected: (id) {
                                    setState(() => _selectedTrackClip = id);
                                    if (id != null) {
                                      if (id.startsWith('voice')) {
                                        _activePropertiesSection = 'voice';
                                      } else if (id.startsWith('video')) {
                                        _activePropertiesSection = 'bg';
                                      } else if (id.startsWith('audio')) {
                                        _activePropertiesSection = 'audio';
                                      } else if (id.startsWith('caption')) {
                                        _activePropertiesSection = 'body';
                                      }
                                    }
                                  },
                                  tracks: tracks,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeRuler(double totalWidth) {
    final duration = _estimatedDuration;
    double tickInterval = 5.0;
    if (duration <= 15) tickInterval = 1.0;
    else if (duration <= 30) tickInterval = 2.0;
    else if (duration <= 60) tickInterval = 5.0;
    else tickInterval = 10.0;

    return SizedBox(
      height: 22,
      width: totalWidth,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(color: const Color(0xFF1A1A28)),
          // Tick marks
          for (double t = 0; t <= duration; t += tickInterval)
            Positioned(
              left: (t / duration) * totalWidth,
              top: 0,
              bottom: 0,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(width: 1, height: 10, color: Colors.white.withOpacity(0.15)),
                  const SizedBox(width: 2),
                  Text(
                    _formatTime(t),
                    style: TextStyle(
                      fontSize: 8,
                      fontFamily: 'monospace',
                      color: Colors.white.withOpacity(0.3),
                    ),
                  ),
                ],
              ),
            ),
          // Playhead triangle
          Positioned(
            left: (_scrubPosition * totalWidth - 5).clamp(0.0, totalWidth - 10),
            bottom: 0,
            child: CustomPaint(
              size: const Size(10, 10),
              painter: _PlayheadTrianglePainter(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNleTrackLabel(String name, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          border: const Border(bottom: BorderSide(color: Colors.white10)),
          color: color.withOpacity(0.05),
        ),
        child: Row(
          children: [
            Icon(icon, size: 13, color: color.withOpacity(0.7)),
            const SizedBox(width: 6),
            Text(
              name,
              style: TextStyle(
                fontSize: 11,
                color: color.withOpacity(0.8),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
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

// ────────────────────────────────────────────────────────────────
//  NLE Timeline Track Area (handles clip rendering + playhead)
// ────────────────────────────────────────────────────────────────

class _NleClipData {
  final String id;
  final String label;
  final double startFrac; // 0.0–1.0
  final double endFrac;   // 0.0–1.0

  _NleClipData({
    required this.id,
    required this.label,
    required this.startFrac,
    required this.endFrac,
  });
}

class _NleTrackData {
  final Color color;
  final List<_NleClipData> clips;

  _NleTrackData({required this.color, required this.clips});
}

class _TimelineTrackArea extends StatelessWidget {
  final double totalWidth;
  final double scrubPosition;
  final double estimatedDuration;
  final ValueChanged<double> onScrub;
  final VoidCallback onScrubEnd;
  final String? selectedClipId;
  final ValueChanged<String?> onClipSelected;
  final List<_NleTrackData> tracks;

  const _TimelineTrackArea({
    required this.totalWidth,
    required this.scrubPosition,
    required this.estimatedDuration,
    required this.onScrub,
    required this.onScrubEnd,
    this.selectedClipId,
    required this.onClipSelected,
    required this.tracks,
  });

  void _handlePointerScrub(Offset localPosition) {
    final pos = (localPosition.dx / totalWidth).clamp(0.0, 1.0);
    onScrub(pos);
  }

  @override
  Widget build(BuildContext context) {
    final playheadX = (scrubPosition * totalWidth).clamp(0.0, totalWidth);

    return SizedBox(
      width: totalWidth,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Background: track rows (tappable for scrubbing via Listener)
          Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (e) => _handlePointerScrub(e.localPosition),
            onPointerMove: (e) => _handlePointerScrub(e.localPosition),
            onPointerUp: (_) => onScrubEnd(),
            child: Column(
              children: tracks.map((track) {
                return Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      border: const Border(bottom: BorderSide(color: Colors.white10)),
                      color: track.color.withOpacity(0.06),
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // Grid lines
                        for (int i = 0; i <= (estimatedDuration / 5).ceil(); i++)
                          Positioned(
                            left: (i * 5 / estimatedDuration) * totalWidth,
                            top: 0,
                            bottom: 0,
                            child: Container(
                              width: 1,
                              color: Colors.white.withOpacity(0.03),
                            ),
                          ),
                        // Clips — use GestureDetector so taps on clips are handled
                        for (final clip in track.clips)
                          Builder(builder: (context) {
                            final isSelected = clip.id == selectedClipId;
                            final clipLeft = clip.startFrac * totalWidth;
                            final clipWidth = (clip.endFrac - clip.startFrac) * totalWidth;

                            return Positioned(
                              left: clipLeft + 2,
                              top: 3,
                              bottom: 3,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => onClipSelected(isSelected ? null : clip.id),
                                child: Container(
                                  width: (clipWidth - 4).clamp(8.0, double.infinity),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? track.color.withOpacity(0.55)
                                        : track.color.withOpacity(0.35),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: isSelected
                                          ? Colors.white.withOpacity(0.6)
                                          : track.color.withOpacity(0.5),
                                      width: isSelected ? 1.5 : 0.5,
                                    ),
                                    boxShadow: isSelected
                                        ? [BoxShadow(color: track.color.withOpacity(0.3), blurRadius: 6)]
                                        : null,
                                  ),
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        clip.label,
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white.withOpacity(isSelected ? 0.95 : 0.7),
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                      ),
                                      if (clipWidth > 60)
                                        Text(
                                          '${(clip.startFrac * estimatedDuration).toStringAsFixed(1)}s – ${(clip.endFrac * estimatedDuration).toStringAsFixed(1)}s',
                                          style: TextStyle(
                                            fontSize: 8,
                                            color: Colors.white.withOpacity(0.35),
                                            fontFamily: 'monospace',
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          // Playhead line
          Positioned(
            left: playheadX,
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Container(width: 2, color: Colors.redAccent),
            ),
          ),
          // Playhead handle
          Positioned(
            left: (playheadX - 6).clamp(0.0, totalWidth - 12),
            top: 0,
            child: IgnorePointer(
              child: Container(
                width: 12,
                height: 12,
                decoration: const BoxDecoration(
                  color: Colors.redAccent,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Playhead triangle painter for the time ruler
class _PlayheadTrianglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.redAccent;
    final path = Path()
      ..moveTo(0, size.height)
      ..lineTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ────────────────────────────────────────────────────────────────
//  LAYOUT PRESETS
// ────────────────────────────────────────────────────────────────

class _LayoutPreset {
  final String name;
  final IconData icon;
  final Color accentColor;
  // Title
  final String titleFont;
  final double titleSize;
  final bool titleBold;
  final String titleAlign;
  final int titleColor;
  final bool titleShadow;
  final bool titleBgEnabled;
  final int titleBgColor;
  final double titleBgOpacity;
  final double titlePosX;
  final double titlePosY;
  // Body
  final String bodyFont;
  final double bodySize;
  final bool bodyBold;
  final String bodyAlign;
  final int bodyColor;
  final bool bodyShadow;
  final bool bodyBgEnabled;
  final int bodyBgColor;
  final double bodyBgOpacity;
  final double bodyPosX;
  final double bodyPosY;
  final double bodyBoxW;
  final double bodyBoxH;

  const _LayoutPreset({
    required this.name,
    required this.icon,
    required this.accentColor,
    required this.titleFont,
    required this.titleSize,
    required this.titleBold,
    required this.titleAlign,
    required this.titleColor,
    required this.titleShadow,
    required this.titleBgEnabled,
    required this.titleBgColor,
    required this.titleBgOpacity,
    required this.titlePosX,
    required this.titlePosY,
    required this.bodyFont,
    required this.bodySize,
    required this.bodyBold,
    required this.bodyAlign,
    required this.bodyColor,
    required this.bodyShadow,
    required this.bodyBgEnabled,
    required this.bodyBgColor,
    required this.bodyBgOpacity,
    required this.bodyPosX,
    required this.bodyPosY,
    required this.bodyBoxW,
    required this.bodyBoxH,
  });

  /// The default "Auto Setup" — clean, centered, readable.
  static const standard = _LayoutPreset(
    name: 'Standard',
    icon: Icons.auto_awesome,
    accentColor: Color(0xFF6C5CE7),
    titleFont: 'Montserrat', titleSize: 52, titleBold: true,
    titleAlign: 'center', titleColor: 0xFFFFFFFF, titleShadow: true,
    titleBgEnabled: true, titleBgColor: 0xFF000000, titleBgOpacity: 0.5,
    titlePosX: 0.5, titlePosY: 0.06,
    bodyFont: 'Inter', bodySize: 38, bodyBold: false,
    bodyAlign: 'center', bodyColor: 0xFFFFFFFF, bodyShadow: true,
    bodyBgEnabled: true, bodyBgColor: 0xFF000000, bodyBgOpacity: 0.4,
    bodyPosX: 0.5, bodyPosY: 0.75, bodyBoxW: 0.9, bodyBoxH: 0.35,
  );

  static const all = <_LayoutPreset>[
    // Bold & Centered — big title top, body center-bottom
    _LayoutPreset(
      name: 'Bold Center',
      icon: Icons.format_bold,
      accentColor: Color(0xFFFF5252),
      titleFont: 'Oswald', titleSize: 60, titleBold: true,
      titleAlign: 'center', titleColor: 0xFFFFFFFF, titleShadow: true,
      titleBgEnabled: false, titleBgColor: 0xFF000000, titleBgOpacity: 0.5,
      titlePosX: 0.5, titlePosY: 0.05,
      bodyFont: 'Inter', bodySize: 36, bodyBold: false,
      bodyAlign: 'center', bodyColor: 0xFFFFFFFF, bodyShadow: true,
      bodyBgEnabled: false, bodyBgColor: 0xFF000000, bodyBgOpacity: 0.4,
      bodyPosX: 0.5, bodyPosY: 0.78, bodyBoxW: 0.85, bodyBoxH: 0.30,
    ),
    // News Style — title bar at top, body boxed at bottom
    _LayoutPreset(
      name: 'News',
      icon: Icons.newspaper,
      accentColor: Color(0xFF40C4FF),
      titleFont: 'Roboto', titleSize: 44, titleBold: true,
      titleAlign: 'left', titleColor: 0xFFFFFFFF, titleShadow: false,
      titleBgEnabled: true, titleBgColor: 0xFF1A1A2E, titleBgOpacity: 0.85,
      titlePosX: 0.5, titlePosY: 0.04,
      bodyFont: 'Roboto', bodySize: 34, bodyBold: false,
      bodyAlign: 'left', bodyColor: 0xFFFFFFFF, bodyShadow: false,
      bodyBgEnabled: true, bodyBgColor: 0xFF000000, bodyBgOpacity: 0.7,
      bodyPosX: 0.5, bodyPosY: 0.82, bodyBoxW: 0.95, bodyBoxH: 0.28,
    ),
    // Minimal — small text, clean
    _LayoutPreset(
      name: 'Minimal',
      icon: Icons.remove_circle_outline,
      accentColor: Color(0xFFBDBDBD),
      titleFont: 'Lato', titleSize: 40, titleBold: false,
      titleAlign: 'center', titleColor: 0xFFFFFFFF, titleShadow: true,
      titleBgEnabled: false, titleBgColor: 0xFF000000, titleBgOpacity: 0.5,
      titlePosX: 0.5, titlePosY: 0.08,
      bodyFont: 'Lato', bodySize: 32, bodyBold: false,
      bodyAlign: 'center', bodyColor: 0xFFFFFFFF, bodyShadow: true,
      bodyBgEnabled: false, bodyBgColor: 0xFF000000, bodyBgOpacity: 0.4,
      bodyPosX: 0.5, bodyPosY: 0.70, bodyBoxW: 0.80, bodyBoxH: 0.35,
    ),
    // Impact — huge title, compact body
    _LayoutPreset(
      name: 'Impact',
      icon: Icons.flash_on,
      accentColor: Color(0xFFFFD700),
      titleFont: 'Oswald', titleSize: 72, titleBold: true,
      titleAlign: 'center', titleColor: 0xFFFFD700, titleShadow: true,
      titleBgEnabled: false, titleBgColor: 0xFF000000, titleBgOpacity: 0.5,
      titlePosX: 0.5, titlePosY: 0.08,
      bodyFont: 'Montserrat', bodySize: 34, bodyBold: false,
      bodyAlign: 'center', bodyColor: 0xFFFFFFFF, bodyShadow: true,
      bodyBgEnabled: true, bodyBgColor: 0xFF000000, bodyBgOpacity: 0.5,
      bodyPosX: 0.5, bodyPosY: 0.80, bodyBoxW: 0.85, bodyBoxH: 0.25,
    ),
    // Caption Style — body fills most of the screen
    _LayoutPreset(
      name: 'Full Caption',
      icon: Icons.subtitles,
      accentColor: Color(0xFF00C853),
      titleFont: 'Poppins', titleSize: 48, titleBold: true,
      titleAlign: 'center', titleColor: 0xFFFFFFFF, titleShadow: true,
      titleBgEnabled: true, titleBgColor: 0xFF6C5CE7, titleBgOpacity: 0.8,
      titlePosX: 0.5, titlePosY: 0.03,
      bodyFont: 'Poppins', bodySize: 42, bodyBold: false,
      bodyAlign: 'center', bodyColor: 0xFFFFFFFF, bodyShadow: true,
      bodyBgEnabled: true, bodyBgColor: 0xFF000000, bodyBgOpacity: 0.5,
      bodyPosX: 0.5, bodyPosY: 0.55, bodyBoxW: 0.90, bodyBoxH: 0.50,
    ),
  ];
}
