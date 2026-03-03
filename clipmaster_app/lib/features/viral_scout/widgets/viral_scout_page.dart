import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/ipc/ipc_client.dart';
import '../../../core/ipc/ipc_message.dart';
import '../../../core/services/activity_service.dart';
import '../../../core/services/api_key_service.dart';
import '../../../core/ui/video_player_overlay.dart';
import '../../../core/utils/env_config.dart';

/// Viral Scout — channel-first discovery engine.
///
/// Modes:
///   1. Trending — ranked list of trending videos (existing behavior)
///   2. Video Search — search for videos by topic/keyword
///   3. Channel Discovery — search channel → VOD grid → clip sidebar
///
/// All downloads run in the background via [ActivityNotifier].
class ViralScoutPage extends ConsumerStatefulWidget {
  const ViralScoutPage({super.key});

  @override
  ConsumerState<ViralScoutPage> createState() => _ViralScoutPageState();
}

enum _ScoutView { trending, search, channel, vods, clips }

class _ViralScoutPageState extends ConsumerState<ViralScoutPage> {
  String _platform = 'youtube';
  _ScoutView _currentView = _ScoutView.trending;

  // Trending state
  bool _isLoading = false;
  String _progressStage = '';
  int _progressPercent = 0;
  List<Map<String, dynamic>> _videos = [];
  String? _error;

  // Search state
  final _searchController = TextEditingController();
  bool _isSearching = false;
  List<Map<String, dynamic>> _searchResults = [];

  // Channel search state
  final _channelSearchController = TextEditingController();
  Map<String, dynamic>? _channelInfo;
  bool _isSearchingChannel = false;

  // VODs state
  List<Map<String, dynamic>> _vods = [];
  bool _isLoadingVods = false;

  // Clips state
  List<Map<String, dynamic>> _clips = [];
  bool _isLoadingClips = false;
  String? _selectedVodTitle;

  // Sidecar readiness
  bool _sidecarReady = false;

  @override
  void initState() {
    super.initState();
    _waitForSidecar();
  }

  /// Wait until the IPC sidecar is connected before auto-fetching.
  Future<void> _waitForSidecar() async {
    final ipc = ref.read(ipcClientProvider);
    // Poll until connected (up to ~10 seconds).
    for (int i = 0; i < 20; i++) {
      if (ipc.isConnected) break;
      await Future.delayed(const Duration(milliseconds: 500));
    }
    if (!mounted) return;
    setState(() => _sidecarReady = ipc.isConnected);
    if (_sidecarReady) {
      _fetchTrending();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _channelSearchController.dispose();
    super.dispose();
  }

  // ── Credentials builder ──

  Map<String, dynamic> _buildCredentials() {
    final apiKeyService = ref.read(apiKeyServiceProvider);
    final payload = <String, dynamic>{'platform': _platform};
    final youtubeKey = apiKeyService.getNextKey(LlmProvider.youtube);
    if (youtubeKey != null) payload['api_key'] = youtubeKey;
    if (_platform == 'twitch') {
      final cid = EnvConfig.get('TWITCH_CLIENT_ID') ?? '';
      final cs = EnvConfig.get('TWITCH_CLIENT_SECRET') ?? '';
      if (cid.isNotEmpty) payload['twitch_client_id'] = cid;
      if (cs.isNotEmpty) payload['twitch_client_secret'] = cs;
    }
    return payload;
  }

  // ── Trending ──

  Future<void> _fetchTrending() async {
    if (!_sidecarReady) return;
    setState(() {
      _isLoading = true;
      _error = null;
      _currentView = _ScoutView.trending;
      _progressStage = 'Starting';
      _progressPercent = 0;
    });
    try {
      final payload = _buildCredentials();
      payload['limit'] = 20;
      final ipc = ref.read(ipcClientProvider);
      final response = await ipc.send(
        IpcMessage(type: MessageType.scoutTrending, payload: payload),
        timeout: const Duration(seconds: 120),
        onProgress: (p) {
          if (mounted) {
            setState(() {
              _progressStage = p.payload['stage'] as String? ?? 'Scouting';
              _progressPercent = p.payload['percent'] as int? ?? 0;
            });
          }
        },
      );
      if (!mounted) return;
      if (response.type == MessageType.error) {
        setState(() {
          _isLoading = false;
          _error = response.payload['message'] as String? ?? 'Unknown error';
        });
      } else {
        setState(() {
          _isLoading = false;
          _videos = (response.payload['videos'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = e.toString();
        });
      }
    }
  }

  // ── Video Search ──

  Future<void> _searchVideos() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    if (!_sidecarReady) return;
    setState(() {
      _isSearching = true;
      _error = null;
      _currentView = _ScoutView.search;
      _searchResults = [];
    });
    try {
      final payload = _buildCredentials();
      payload['query'] = query;
      payload['limit'] = 20;
      final ipc = ref.read(ipcClientProvider);
      final response = await ipc.send(
        IpcMessage(type: MessageType.scoutTrending, payload: payload),
        timeout: const Duration(seconds: 60),
        onProgress: (p) {
          if (mounted) {
            setState(() {
              _progressStage = p.payload['stage'] as String? ?? 'Searching';
              _progressPercent = p.payload['percent'] as int? ?? 0;
            });
          }
        },
      );
      if (!mounted) return;
      if (response.type == MessageType.error) {
        setState(() {
          _isSearching = false;
          _error = response.payload['message'] as String?;
        });
      } else {
        setState(() {
          _isSearching = false;
          _searchResults =
              (response.payload['videos'] as List<dynamic>? ?? [])
                  .cast<Map<String, dynamic>>();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSearching = false;
          _error = e.toString();
        });
      }
    }
  }

  // ── Channel Search ──

  Future<void> _searchChannel() async {
    final query = _channelSearchController.text.trim();
    if (query.isEmpty) return;
    if (!_sidecarReady) return;
    setState(() {
      _isSearchingChannel = true;
      _channelInfo = null;
      _vods = [];
      _clips = [];
      _error = null;
    });
    try {
      final payload = _buildCredentials();
      payload['query'] = query;
      final ipc = ref.read(ipcClientProvider);
      final response = await ipc.send(
        IpcMessage(type: MessageType.scoutChannel, payload: payload),
        timeout: const Duration(seconds: 30),
      );
      if (!mounted) return;
      if (response.type == MessageType.error) {
        setState(() {
          _isSearchingChannel = false;
          _error = response.payload['message'] as String?;
        });
      } else {
        // Server returns {"channel": {...}} — unwrap it.
        final channelData =
            response.payload['channel'] as Map<String, dynamic>?;
        if (channelData == null) {
          setState(() {
            _isSearchingChannel = false;
            _error = 'No channel data returned.';
          });
          return;
        }
        setState(() {
          _isSearchingChannel = false;
          _channelInfo = channelData;
          _currentView = _ScoutView.channel;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSearchingChannel = false;
          _error = e.toString();
        });
      }
    }
  }

  // ── VODs ──

  Future<void> _fetchVods() async {
    if (_channelInfo == null || !_sidecarReady) return;
    setState(() {
      _isLoadingVods = true;
      _error = null;
    });
    try {
      final payload = _buildCredentials();
      // YouTube uses 'channel_id', Twitch uses 'user_id'
      if (_platform == 'twitch') {
        payload['user_id'] = _channelInfo!['user_id'] as String? ?? '';
      } else {
        payload['channel_id'] = _channelInfo!['channel_id'] as String? ?? '';
      }
      payload['limit'] = 20;
      final ipc = ref.read(ipcClientProvider);
      final response = await ipc.send(
        IpcMessage(type: MessageType.scoutVods, payload: payload),
        timeout: const Duration(seconds: 30),
      );
      if (!mounted) return;
      if (response.type == MessageType.error) {
        setState(() {
          _isLoadingVods = false;
          _error = response.payload['message'] as String?;
        });
      } else {
        setState(() {
          _isLoadingVods = false;
          _vods = (response.payload['vods'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>();
          _currentView = _ScoutView.vods;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingVods = false;
          _error = e.toString();
        });
      }
    }
  }

  // ── Clips ──

  Future<void> _fetchClips(String vodId, String vodTitle) async {
    if (!_sidecarReady) return;
    setState(() {
      _isLoadingClips = true;
      _selectedVodTitle = vodTitle;
      _clips = [];
      _error = null;
    });
    try {
      final payload = _buildCredentials();
      if (_platform == 'twitch') {
        payload['broadcaster_id'] =
            _channelInfo?['user_id'] as String? ?? '';
        payload['vod_id'] = vodId;
      } else {
        payload['channel_id'] =
            _channelInfo?['channel_id'] as String? ?? '';
        payload['vod_id'] = vodId;
      }
      payload['limit'] = 20;
      final ipc = ref.read(ipcClientProvider);
      final response = await ipc.send(
        IpcMessage(type: MessageType.scoutClips, payload: payload),
        timeout: const Duration(seconds: 30),
      );
      if (!mounted) return;
      if (response.type == MessageType.error) {
        setState(() {
          _isLoadingClips = false;
          _error = response.payload['message'] as String?;
        });
      } else {
        setState(() {
          _isLoadingClips = false;
          _clips = (response.payload['clips'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>();
          _currentView = _ScoutView.clips;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingClips = false;
          _error = e.toString();
        });
      }
    }
  }

  // ── Background Download ──

  void _downloadVideo(Map<String, dynamic> video) {
    final url = video['url'] as String? ?? '';
    if (url.isEmpty) return;
    final title = video['title'] as String? ?? 'Untitled';
    final taskId =
        'dl_${DateTime.now().millisecondsSinceEpoch}_${url.hashCode}';

    ref.read(activityProvider.notifier).addTask(
          id: taskId,
          category: TaskCategory.download,
          title: title,
          subtitle: _platform.toUpperCase(),
          metadata: video,
        );

    final ipc = ref.read(ipcClientProvider);
    ipc
        .send(
      IpcMessage(
          type: MessageType.downloadClip,
          payload: <String, dynamic>{'url': url}),
      timeout: const Duration(minutes: 15),
      onProgress: (p) {
        ref.read(activityProvider.notifier).updateProgress(
              taskId,
              percent: p.payload['percent'] as int? ?? 0,
              stage: p.payload['stage'] as String? ?? 'Downloading',
            );
      },
    )
        .then((response) {
      if (response.type == MessageType.error) {
        ref.read(activityProvider.notifier).fail(
              taskId,
              response.payload['message'] as String? ?? 'Download failed',
            );
      } else {
        ref.read(activityProvider.notifier).complete(
              taskId,
              resultPath: response.payload['path'] as String?,
            );
      }
    }).catchError((Object e) {
      ref.read(activityProvider.notifier).fail(taskId, e.toString());
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Downloading "$title" in background...'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _downloadClip(Map<String, dynamic> clip) {
    final url = clip['url'] as String? ?? clip['embed_url'] as String? ?? '';
    if (url.isEmpty) return;
    final title = clip['title'] as String? ?? 'Untitled Clip';
    final taskId =
        'dl_clip_${DateTime.now().millisecondsSinceEpoch}_${url.hashCode}';

    ref.read(activityProvider.notifier).addTask(
          id: taskId,
          category: TaskCategory.download,
          title: title,
          subtitle:
              'Clip from ${_channelInfo?['display_name'] ?? _channelInfo?['title'] ?? 'channel'}',
          metadata: clip,
        );

    final ipc = ref.read(ipcClientProvider);
    final payload = <String, dynamic>{'url': url};
    if (clip['vod_offset'] != null && clip['duration'] != null) {
      payload['start_time'] = clip['vod_offset'];
      payload['end_time'] = (clip['vod_offset'] as num).toDouble() +
          (clip['duration'] as num).toDouble();
    }

    ipc
        .send(
      IpcMessage(type: MessageType.downloadClip, payload: payload),
      timeout: const Duration(minutes: 10),
      onProgress: (p) {
        ref.read(activityProvider.notifier).updateProgress(
              taskId,
              percent: p.payload['percent'] as int? ?? 0,
              stage: p.payload['stage'] as String? ?? 'Downloading',
            );
      },
    )
        .then((response) {
      if (response.type == MessageType.error) {
        ref.read(activityProvider.notifier).fail(
              taskId,
              response.payload['message'] as String? ?? 'Download failed',
            );
      } else {
        ref.read(activityProvider.notifier).complete(
              taskId,
              resultPath: response.payload['path'] as String?,
            );
      }
    }).catchError((Object e) {
      ref.read(activityProvider.notifier).fail(taskId, e.toString());
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Downloading clip "$title" in background...'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  // ── Video Preview ──

  void _previewVideo(Map<String, dynamic> video) {
    final url = video['url'] as String? ?? '';
    if (url.isEmpty) return;
    final title = video['title'] as String? ?? 'Video';
    VideoPlayerOverlay.show(context, url: url, title: title);
  }

  // ── Navigation ──

  void _goBack() {
    setState(() {
      switch (_currentView) {
        case _ScoutView.clips:
          _currentView = _ScoutView.vods;
          _clips = [];
        case _ScoutView.vods:
          _currentView = _ScoutView.channel;
        case _ScoutView.channel:
          _currentView = _ScoutView.trending;
          _channelInfo = null;
          _vods = [];
          _clips = [];
        case _ScoutView.search:
          _currentView = _ScoutView.trending;
          _searchResults = [];
        case _ScoutView.trending:
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!_sidecarReady) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Waiting for sidecar to connect...',
                style: TextStyle(color: Colors.white38)),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              if (_currentView != _ScoutView.trending)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, size: 20),
                    onPressed: _goBack,
                    tooltip: 'Back',
                  ),
                ),
              const Icon(
                  Icons.trending_up, size: 28, color: Color(0xFF6C5CE7)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _headerTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _headerSubtitle,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: Colors.white.withOpacity(0.4)),
          ),
          const SizedBox(height: 16),
          // Controls bar
          _buildControlsBar(theme),
          const SizedBox(height: 16),
          // Content
          Expanded(child: _buildContent(theme)),
        ],
      ),
    );
  }

  String get _headerTitle {
    return switch (_currentView) {
      _ScoutView.trending => 'Viral Scout',
      _ScoutView.search =>
        'Search: "${_searchController.text.trim()}"',
      _ScoutView.channel =>
        _channelInfo?['display_name'] as String? ??
            _channelInfo?['title'] as String? ??
            'Channel',
      _ScoutView.vods =>
        '${_channelInfo?['display_name'] ?? _channelInfo?['title'] ?? 'Channel'} — Videos',
      _ScoutView.clips => _selectedVodTitle ?? 'Clips',
    };
  }

  String get _headerSubtitle {
    return switch (_currentView) {
      _ScoutView.trending =>
        'Discover trending videos ranked by viral clip potential.',
      _ScoutView.search =>
        '${_searchResults.length} results. Click thumbnail to preview, download icon to save.',
      _ScoutView.channel => 'Channel found. Click "View Videos" to browse.',
      _ScoutView.vods =>
        '${_vods.length} videos. Click to preview or browse clips.',
      _ScoutView.clips =>
        '${_clips.length} clips found. Download to use in your projects.',
    };
  }

  Widget _buildControlsBar(ThemeData theme) {
    return Row(
      children: [
        // Platform selector
        DropdownButton<String>(
          value: _platform,
          items: const [
            DropdownMenuItem(value: 'youtube', child: Text('YouTube')),
            DropdownMenuItem(value: 'twitch', child: Text('Twitch')),
          ],
          onChanged: (p) {
            if (p == null) return;
            setState(() => _platform = p);
          },
        ),
        const SizedBox(width: 12),
        // Video search bar
        SizedBox(
          width: 220,
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search videos...',
              prefixIcon: const Icon(Icons.search, size: 18),
              border: const OutlineInputBorder(),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              suffixIcon: _isSearching
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : null,
            ),
            onSubmitted: (_) => _searchVideos(),
          ),
        ),
        const SizedBox(width: 4),
        FilledButton(
          onPressed: _isSearching ? null : _searchVideos,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          ),
          child: const Text('Search'),
        ),
        const SizedBox(width: 12),
        Container(width: 1, height: 32, color: Colors.white12),
        const SizedBox(width: 12),
        // Channel search bar
        SizedBox(
          width: 200,
          child: TextField(
            controller: _channelSearchController,
            decoration: InputDecoration(
              hintText: 'Channel name...',
              prefixIcon: const Icon(Icons.person_search, size: 18),
              border: const OutlineInputBorder(),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              suffixIcon: _isSearchingChannel
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : null,
            ),
            onSubmitted: (_) => _searchChannel(),
          ),
        ),
        const SizedBox(width: 4),
        FilledButton(
          onPressed: _isSearchingChannel ? null : _searchChannel,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            backgroundColor: Colors.white10,
          ),
          child: const Text('Find Channel'),
        ),
        const SizedBox(width: 12),
        Container(width: 1, height: 32, color: Colors.white12),
        const SizedBox(width: 12),
        FilledButton.icon(
          onPressed: _isLoading ? null : _fetchTrending,
          icon: const Icon(Icons.trending_up, size: 18),
          label: const Text('Trending'),
          style: FilledButton.styleFrom(
            backgroundColor: _currentView == _ScoutView.trending
                ? const Color(0xFF6C5CE7)
                : Colors.white10,
          ),
        ),
        const Spacer(),
        if (_currentView == _ScoutView.trending && _videos.isNotEmpty)
          Text(
            '${_videos.length} videos',
            style: const TextStyle(fontSize: 12, color: Colors.white38),
          ),
      ],
    );
  }

  Widget _buildContent(ThemeData theme) {
    if (_error != null &&
        ((_currentView == _ScoutView.trending && _videos.isEmpty) ||
            (_currentView == _ScoutView.search && _searchResults.isEmpty) ||
            (_currentView != _ScoutView.trending &&
                _currentView != _ScoutView.search))) {
      return _buildErrorState();
    }

    return switch (_currentView) {
      _ScoutView.trending => _buildTrendingView(theme),
      _ScoutView.search => _buildSearchView(theme),
      _ScoutView.channel => _buildChannelView(theme),
      _ScoutView.vods => _buildVodsView(theme),
      _ScoutView.clips => _buildClipsView(theme),
    };
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
          const SizedBox(height: 16),
          SizedBox(
            width: 400,
            child: Text(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent)),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              setState(() => _error = null);
              if (_currentView == _ScoutView.trending) _fetchTrending();
            },
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  // ── Trending View ──

  Widget _buildTrendingView(ThemeData theme) {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('$_progressStage... $_progressPercent%'),
          ],
        ),
      );
    }

    if (_videos.isEmpty) {
      return _buildEmptyVideoState(
        'No trending videos found.',
        _platform == 'youtube'
            ? 'Add a YouTube Data API key in Settings.'
            : 'Add TWITCH_CLIENT_ID and TWITCH_CLIENT_SECRET in .env.',
      );
    }

    return _buildVideoList(_videos);
  }

  // ── Search View ──

  Widget _buildSearchView(ThemeData theme) {
    if (_isSearching) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('$_progressStage... $_progressPercent%'),
          ],
        ),
      );
    }

    if (_searchResults.isEmpty) {
      return _buildEmptyVideoState(
        'No results found.',
        'Try a different search term or check your API key.',
      );
    }

    return _buildVideoList(_searchResults);
  }

  Widget _buildEmptyVideoState(String title, String subtitle) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.video_library_outlined,
              size: 64, color: Colors.white24),
          const SizedBox(height: 16),
          Text(title,
              style: const TextStyle(color: Colors.white38, fontSize: 15)),
          const SizedBox(height: 8),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white24, fontSize: 12)),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _fetchTrending,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoList(List<Map<String, dynamic>> videos) {
    return ListView.builder(
      itemCount: videos.length,
      itemBuilder: (context, index) {
        return _VideoCard(
          video: videos[index],
          rank: index + 1,
          onDownload: () => _downloadVideo(videos[index]),
          onPreview: () => _previewVideo(videos[index]),
        );
      },
    );
  }

  // ── Channel View ──

  Widget _buildChannelView(ThemeData theme) {
    if (_channelInfo == null) {
      return const Center(
        child: Text('Search for a channel above.',
            style: TextStyle(color: Colors.white38)),
      );
    }

    final name = _channelInfo!['display_name'] as String? ??
        _channelInfo!['title'] as String? ??
        'Unknown';
    final profileImg = _channelInfo!['profile_image_url'] as String? ??
        _channelInfo!['thumbnail_url'] as String? ??
        '';
    final description = _channelInfo!['description'] as String? ?? '';
    final viewCount = _channelInfo!['view_count'] as int? ??
        _channelInfo!['subscriber_count'] as int? ??
        0;
    final videoCount = _channelInfo!['video_count'] as int? ?? 0;

    return Column(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                if (profileImg.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(40),
                    child: Image.network(profileImg,
                        width: 64,
                        height: 64,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                            width: 64,
                            height: 64,
                            color: Colors.white10,
                            child: const Icon(Icons.person, size: 32))),
                  ),
                if (profileImg.isNotEmpty) const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: theme.textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      if (description.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.5),
                                fontSize: 13)),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(
                            '${_formatCount(viewCount)} ${_platform == 'twitch' ? 'total views' : 'subscribers'}',
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 12),
                          ),
                          if (videoCount > 0) ...[
                            const Text('  ·  ',
                                style: TextStyle(color: Colors.white24)),
                            Text('$videoCount videos',
                                style: const TextStyle(
                                    color: Colors.white38, fontSize: 12)),
                          ],
                          Text('  ·  $_platform',
                              style: const TextStyle(
                                  color: Colors.white24, fontSize: 12)),
                        ],
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: _isLoadingVods ? null : _fetchVods,
                  icon: const Icon(Icons.video_library, size: 18),
                  label: Text(_isLoadingVods ? 'Loading...' : 'View Videos'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (_isLoadingVods)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_vods.isNotEmpty)
          Expanded(child: _buildVodGrid(theme))
        else
          const Expanded(
            child: Center(
              child: Text('Click "View Videos" to load content.',
                  style: TextStyle(color: Colors.white38)),
            ),
          ),
      ],
    );
  }

  // ── VODs View ──

  Widget _buildVodsView(ThemeData theme) {
    if (_isLoadingVods) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_vods.isEmpty) {
      return const Center(
        child: Text('No videos found for this channel.',
            style: TextStyle(color: Colors.white38)),
      );
    }
    return _buildVodGrid(theme);
  }

  Widget _buildVodGrid(ThemeData theme) {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 340,
        childAspectRatio: 16 / 12,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: _vods.length,
      itemBuilder: (context, index) {
        final vod = _vods[index];
        final vodId = vod['vod_id'] as String? ??
            vod['video_id'] as String? ??
            '';
        final title = vod['title'] as String? ?? 'Untitled';
        final thumbnail = vod['thumbnail_url'] as String? ?? '';
        final viewCount = vod['view_count'] as int? ?? 0;
        final duration = vod['duration'] as String? ?? '';
        final dateStr = vod['created_at'] as String? ??
            vod['published_at'] as String? ??
            '';
        final url = vod['url'] as String? ?? '';

        return Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () {
              if (_platform == 'twitch') {
                _fetchClips(vodId, title);
              } else if (url.isNotEmpty) {
                VideoPlayerOverlay.show(context, url: url, title: title);
              }
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (thumbnail.isNotEmpty)
                        Image.network(thumbnail, fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                                color: Colors.white10,
                                child: const Icon(Icons.video_library,
                                    size: 32, color: Colors.white24)))
                      else
                        Container(
                          color: Colors.white10,
                          child: const Icon(Icons.video_library,
                              size: 32, color: Colors.white24),
                        ),
                      if (duration.isNotEmpty)
                        Positioned(
                          bottom: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(duration,
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.white)),
                          ),
                        ),
                      Center(
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Colors.black45,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Icon(Icons.play_arrow,
                              size: 24, color: Colors.white70),
                        ),
                      ),
                      if (url.isNotEmpty)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Material(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(16),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () => _downloadVideo(vod),
                              child: const Padding(
                                padding: EdgeInsets.all(6),
                                child: Icon(Icons.download,
                                    size: 16, color: Colors.white70),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(
                            '${_formatCount(viewCount)} views',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.white38),
                          ),
                          if (dateStr.isNotEmpty) ...[
                            const Text(' · ',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.white24)),
                            Text(_formatDate(dateStr),
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.white38)),
                          ],
                          if (_platform == 'twitch') ...[
                            const Spacer(),
                            const Icon(Icons.content_cut,
                                size: 12, color: Colors.white24),
                            const SizedBox(width: 4),
                            const Text('Clips',
                                style: TextStyle(
                                    fontSize: 10, color: Colors.white24)),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Clips View ──

  Widget _buildClipsView(ThemeData theme) {
    if (_isLoadingClips) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_clips.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.content_cut, size: 48, color: Colors.white24),
            const SizedBox(height: 16),
            const Text('No clips found for this VOD.',
                style: TextStyle(color: Colors.white38, fontSize: 14)),
            const SizedBox(height: 8),
            const Text(
              'This VOD may not have viewer-created clips yet.',
              style: TextStyle(color: Colors.white24, fontSize: 12),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _goBack,
              icon: const Icon(Icons.arrow_back),
              label: const Text('Back to Videos'),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _clips.length,
      itemBuilder: (context, index) {
        final clip = _clips[index];
        final title = clip['title'] as String? ?? 'Untitled Clip';
        final thumbnail = clip['thumbnail_url'] as String? ?? '';
        final viewCount = clip['view_count'] as int? ?? 0;
        final duration = (clip['duration'] as num?)?.toDouble() ?? 0.0;
        final creatorName = clip['creator_name'] as String? ?? '';
        final vodOffset = clip['vod_offset'] as int? ?? 0;
        final clipUrl = clip['url'] as String? ?? '';

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                // Thumbnail with play overlay
                if (thumbnail.isNotEmpty)
                  GestureDetector(
                    onTap: clipUrl.isNotEmpty
                        ? () => _previewVideo(clip)
                        : null,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        width: 140,
                        height: 80,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.network(thumbnail, fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                    color: Colors.white10,
                                    child: const Icon(Icons.broken_image,
                                        size: 24, color: Colors.white24))),
                            Positioned(
                              bottom: 4,
                              right: 4,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Colors.black87,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: Text(
                                  '${duration.toStringAsFixed(0)}s',
                                  style: const TextStyle(
                                      fontSize: 10, color: Colors.white),
                                ),
                              ),
                            ),
                            Center(
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: Colors.black45,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: const Icon(Icons.play_arrow,
                                    size: 18, color: Colors.white70),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (thumbnail.isNotEmpty) const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(Icons.visibility,
                              size: 12, color: Colors.white38),
                          const SizedBox(width: 4),
                          Text('${_formatCount(viewCount)} views',
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.white54)),
                          if (creatorName.isNotEmpty) ...[
                            const SizedBox(width: 12),
                            const Icon(Icons.person_outline,
                                size: 12, color: Colors.white38),
                            const SizedBox(width: 4),
                            Text(creatorName,
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.white54)),
                          ],
                        ],
                      ),
                      if (vodOffset > 0) ...[
                        const SizedBox(height: 4),
                        Text(
                          'VOD offset: ${_formatDuration(vodOffset)}',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.white38),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.icon(
                      onPressed: () => _downloadClip(clip),
                      icon: const Icon(Icons.download, size: 16),
                      label: const Text('Download'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (clipUrl.isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.play_circle_outline,
                                size: 18),
                            tooltip: 'Preview',
                            onPressed: () => _previewVideo(clip),
                          ),
                        IconButton(
                          icon: const Icon(Icons.link, size: 18),
                          tooltip: 'Copy URL',
                          onPressed: () {
                            if (clipUrl.isNotEmpty) {
                              Clipboard.setData(ClipboardData(text: clipUrl));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('URL copied'),
                                  duration: Duration(seconds: 1),
                                ),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Helpers ──

  String _formatCount(int count) {
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
    return NumberFormat('#,###').format(count);
  }

  String _formatDate(String isoString) {
    try {
      final dt = DateTime.parse(isoString);
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inDays > 30) return DateFormat('MMM d, y').format(dt);
      if (diff.inDays > 0) return '${diff.inDays}d ago';
      if (diff.inHours > 0) return '${diff.inHours}h ago';
      return '${diff.inMinutes}m ago';
    } catch (_) {
      return isoString;
    }
  }

  String _formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m}m ${s}s';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }
}

// ── Video Card (used in trending + search views) ──

class _VideoCard extends StatelessWidget {
  final Map<String, dynamic> video;
  final int rank;
  final VoidCallback onDownload;
  final VoidCallback onPreview;

  const _VideoCard({
    required this.video,
    required this.rank,
    required this.onDownload,
    required this.onPreview,
  });

  @override
  Widget build(BuildContext context) {
    final title = video['title'] as String? ?? 'Untitled';
    final channel = video['channel'] as String? ?? 'Unknown';
    final platform = video['platform'] as String? ?? '';
    final views = video['views'] as int? ?? 0;
    final velocity = (video['velocity_score'] as num?)?.toDouble() ?? 0.0;
    final engagement =
        (video['engagement_density'] as num?)?.toDouble() ?? 0.0;
    final composite =
        (video['composite_score'] as num?)?.toDouble() ?? 0.0;
    final url = video['url'] as String? ?? '';
    final thumbnailUrl = video['thumbnail_url'] as String? ?? '';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            // Rank badge
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: rank <= 3
                    ? const Color(0xFF6C5CE7).withOpacity(0.3)
                    : Colors.white10,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text('#$rank',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color:
                        rank <= 3 ? const Color(0xFF6C5CE7) : Colors.white54,
                  )),
            ),
            const SizedBox(width: 12),
            // Thumbnail (clickable for preview)
            if (thumbnailUrl.isNotEmpty)
              GestureDetector(
                onTap: url.isNotEmpty ? onPreview : null,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 120,
                    height: 68,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.network(thumbnailUrl, fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                                color: Colors.white10,
                                child: const Icon(Icons.broken_image,
                                    size: 24, color: Colors.white24))),
                        Center(
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: Colors.black45,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Icon(Icons.play_arrow,
                                size: 18, color: Colors.white70),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (thumbnailUrl.isNotEmpty) const SizedBox(width: 12),
            // Video info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14)),
                  const SizedBox(height: 4),
                  Text('$channel  ·  ${platform.toUpperCase()}',
                      style: const TextStyle(
                          fontSize: 12, color: Colors.white54)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.visibility,
                          size: 14, color: Colors.white38),
                      const SizedBox(width: 4),
                      Text(_formatCount(views),
                          style: const TextStyle(
                              fontSize: 11, color: Colors.white54)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Scores
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _ScoreBadge('Velocity', _formatVelocity(velocity),
                    Colors.lightBlueAccent),
                const SizedBox(height: 4),
                _ScoreBadge('Engage',
                    '${(engagement * 100).toStringAsFixed(1)}%', Colors.orange),
                const SizedBox(height: 4),
                _ScoreBadge('Score', composite.toStringAsFixed(2),
                    const Color(0xFF6C5CE7)),
              ],
            ),
            const SizedBox(width: 8),
            // Actions
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.play_circle_outline, size: 20),
                  tooltip: 'Preview',
                  onPressed: url.isEmpty ? null : onPreview,
                ),
                IconButton(
                  icon: const Icon(Icons.download, size: 20),
                  tooltip: 'Download',
                  onPressed: url.isEmpty ? null : onDownload,
                ),
                IconButton(
                  icon: const Icon(Icons.link, size: 20),
                  tooltip: 'Copy URL',
                  onPressed: url.isEmpty
                      ? null
                      : () {
                          Clipboard.setData(ClipboardData(text: url));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('URL copied'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatCount(int count) {
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
    return NumberFormat('#,###').format(count);
  }

  String _formatVelocity(double velocity) {
    if (velocity >= 1000000) {
      return '${(velocity / 1000000).toStringAsFixed(1)}M/h';
    }
    if (velocity >= 1000) return '${(velocity / 1000).toStringAsFixed(1)}K/h';
    return '${velocity.toStringAsFixed(0)}/h';
  }
}

class _ScoreBadge extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _ScoreBadge(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label: ',
              style: TextStyle(fontSize: 10, color: color.withOpacity(0.7))),
          Text(value,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }
}
