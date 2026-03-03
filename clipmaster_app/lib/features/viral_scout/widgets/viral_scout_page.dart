import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/ipc/ipc_client.dart';
import '../../../core/ipc/ipc_message.dart';
import '../../../core/services/activity_service.dart';
import '../../../core/services/api_key_service.dart';
import '../../../core/utils/env_config.dart';

/// Viral Scout — channel-first discovery engine.
///
/// Flow:  Search channel → see VODs → see clips per VOD → download clips
/// All downloads run in the background via [ActivityNotifier].
class ViralScoutPage extends ConsumerStatefulWidget {
  const ViralScoutPage({super.key});

  @override
  ConsumerState<ViralScoutPage> createState() => _ViralScoutPageState();
}

enum _ScoutView { trending, channel, vods, clips }

class _ViralScoutPageState extends ConsumerState<ViralScoutPage> {
  String _platform = 'youtube';
  _ScoutView _currentView = _ScoutView.trending;

  // Trending state
  bool _isLoading = false;
  String _progressStage = '';
  int _progressPercent = 0;
  List<Map<String, dynamic>> _videos = [];
  String? _error;

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
  String? _selectedVodId;
  String? _selectedVodTitle;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetchTrending());
  }

  @override
  void dispose() {
    _channelSearchController.dispose();
    super.dispose();
  }

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
    setState(() {
      _isLoading = true;
      _error = null;
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
        onProgress: (p) => setState(() {
          _progressStage = p.payload['stage'] as String? ?? 'Scouting';
          _progressPercent = p.payload['percent'] as int? ?? 0;
        }),
      );
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
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  // ── Channel Search ──

  Future<void> _searchChannel() async {
    final query = _channelSearchController.text.trim();
    if (query.isEmpty) return;
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
      if (response.type == MessageType.error) {
        setState(() {
          _isSearchingChannel = false;
          _error = response.payload['message'] as String?;
        });
      } else {
        setState(() {
          _isSearchingChannel = false;
          _channelInfo = response.payload;
          _currentView = _ScoutView.channel;
        });
        _fetchVods();
      }
    } catch (e) {
      setState(() {
        _isSearchingChannel = false;
        _error = e.toString();
      });
    }
  }

  // ── VODs ──

  Future<void> _fetchVods() async {
    if (_channelInfo == null) return;
    setState(() {
      _isLoadingVods = true;
      _error = null;
    });
    try {
      final payload = _buildCredentials();
      final userId = _channelInfo!['user_id'] as String? ??
          _channelInfo!['channel_id'] as String? ??
          '';
      payload['user_id'] = userId;
      payload['channel_id'] = userId;
      payload['limit'] = 20;
      final ipc = ref.read(ipcClientProvider);
      final response = await ipc.send(
        IpcMessage(type: MessageType.scoutVods, payload: payload),
        timeout: const Duration(seconds: 30),
      );
      if (response.type == MessageType.error) {
        setState(() {
          _isLoadingVods = false;
          _error = response.payload['message'] as String?;
        });
      } else {
        setState(() {
          _isLoadingVods = false;
          _vods = (response.payload['vods'] as List<dynamic>? ??
                  response.payload['videos'] as List<dynamic>? ??
                  [])
              .cast<Map<String, dynamic>>();
          _currentView = _ScoutView.vods;
        });
      }
    } catch (e) {
      setState(() {
        _isLoadingVods = false;
        _error = e.toString();
      });
    }
  }

  // ── Clips ──

  Future<void> _fetchClips(String vodId, String vodTitle) async {
    setState(() {
      _isLoadingClips = true;
      _selectedVodId = vodId;
      _selectedVodTitle = vodTitle;
      _clips = [];
      _error = null;
    });
    try {
      final payload = _buildCredentials();
      final broadcasterId = _channelInfo?['user_id'] as String? ??
          _channelInfo?['channel_id'] as String? ??
          '';
      payload['broadcaster_id'] = broadcasterId;
      payload['channel_id'] = broadcasterId;
      payload['vod_id'] = vodId;
      payload['limit'] = 20;
      final ipc = ref.read(ipcClientProvider);
      final response = await ipc.send(
        IpcMessage(type: MessageType.scoutClips, payload: payload),
        timeout: const Duration(seconds: 30),
      );
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
      setState(() {
        _isLoadingClips = false;
        _error = e.toString();
      });
    }
  }

  // ── Background Download ──

  void _downloadVideo(Map<String, dynamic> video) {
    final url = video['url'] as String? ?? '';
    if (url.isEmpty) return;
    final title = video['title'] as String? ?? 'Untitled';
    final taskId =
        'dl_${DateTime.now().millisecondsSinceEpoch}_${url.hashCode}';

    // Register in Activity tracker
    ref.read(activityProvider.notifier).addTask(
          id: taskId,
          category: TaskCategory.download,
          title: title,
          subtitle: _platform.toUpperCase(),
          metadata: video,
        );

    // Fire-and-forget IPC download
    final ipc = ref.read(ipcClientProvider);
    final payload = <String, dynamic>{'url': url};
    ipc
        .send(
      IpcMessage(type: MessageType.downloadVideo, payload: payload),
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
    }).catchError((e) {
      ref.read(activityProvider.notifier).fail(taskId, e.toString());
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Downloading "$title" in background...'),
        duration: const Duration(seconds: 2),
        action: SnackBarAction(
          label: 'Activity',
          onPressed: () {
            // Switch to Activity tab (index 3 after we add it)
            // The main.dart will be updated to include Activity at index 3
          },
        ),
      ),
    );
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
          subtitle: 'Clip from ${_channelInfo?['display_name'] ?? _channelInfo?['title'] ?? 'channel'}',
          metadata: clip,
        );

    final ipc = ref.read(ipcClientProvider);
    final payload = <String, dynamic>{'url': url};
    if (clip['vod_offset'] != null && clip['duration'] != null) {
      payload['start_time'] = clip['vod_offset'];
      payload['end_time'] =
          (clip['vod_offset'] as num).toDouble() +
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
    }).catchError((e) {
      ref.read(activityProvider.notifier).fail(taskId, e.toString());
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Downloading clip "$title" in background...'),
        duration: const Duration(seconds: 2),
      ),
    );
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
        case _ScoutView.trending:
          break;
      }
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
          // Header
          Row(
            children: [
              if (_currentView != _ScoutView.trending)
                IconButton(
                  icon: const Icon(Icons.arrow_back, size: 20),
                  onPressed: _goBack,
                  tooltip: 'Back',
                ),
              const Icon(
                  Icons.trending_up, size: 28, color: Color(0xFF6C5CE7)),
              const SizedBox(width: 12),
              Text(
                _headerTitle,
                style: theme.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
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
      _ScoutView.channel =>
        _channelInfo?['display_name'] as String? ??
            _channelInfo?['title'] as String? ??
            'Channel',
      _ScoutView.vods =>
        '${_channelInfo?['display_name'] ?? _channelInfo?['title'] ?? 'Channel'} — VODs',
      _ScoutView.clips => _selectedVodTitle ?? 'Clips',
    };
  }

  String get _headerSubtitle {
    return switch (_currentView) {
      _ScoutView.trending =>
        'Discover trending videos ranked by viral clip potential.',
      _ScoutView.channel => 'Search a channel to explore their content.',
      _ScoutView.vods => 'Select a VOD to browse viewer-created clips.',
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
            setState(() {
              _platform = p!;
              if (_currentView == _ScoutView.trending) {
                _fetchTrending();
              }
            });
          },
        ),
        const SizedBox(width: 12),
        // Channel search
        SizedBox(
          width: 280,
          child: TextField(
            controller: _channelSearchController,
            decoration: InputDecoration(
              hintText: _platform == 'twitch'
                  ? 'Search Twitch channel...'
                  : 'Search YouTube channel...',
              prefixIcon: const Icon(Icons.person_search, size: 20),
              border: const OutlineInputBorder(),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              suffixIcon: _isSearchingChannel
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
            onSubmitted: (_) => _searchChannel(),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: _isSearchingChannel ? null : _searchChannel,
          icon: const Icon(Icons.person_search, size: 18),
          label: const Text('Find Channel'),
        ),
        const SizedBox(width: 16),
        Container(width: 1, height: 32, color: Colors.white12),
        const SizedBox(width: 16),
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
        if (_videos.isNotEmpty && _currentView == _ScoutView.trending)
          Text(
            '${_videos.length} videos',
            style: const TextStyle(fontSize: 12, color: Colors.white38),
          ),
      ],
    );
  }

  Widget _buildContent(ThemeData theme) {
    if (_error != null &&
        (_currentView == _ScoutView.trending && _videos.isEmpty ||
            _currentView != _ScoutView.trending)) {
      return _buildErrorState();
    }

    return switch (_currentView) {
      _ScoutView.trending => _buildTrendingView(theme),
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
          Text(_error!, style: const TextStyle(color: Colors.redAccent)),
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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.trending_up, size: 64, color: Colors.white24),
            const SizedBox(height: 16),
            const Text('No trending videos found.',
                style: TextStyle(color: Colors.white38, fontSize: 15)),
            const SizedBox(height: 8),
            Text(
              _platform == 'youtube'
                  ? 'Add a YouTube Data API key in Settings.'
                  : 'Add TWITCH_CLIENT_ID and TWITCH_CLIENT_SECRET in .env.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white24, fontSize: 12),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _fetchTrending,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _videos.length,
      itemBuilder: (context, index) {
        return _TrendingVideoCard(
          video: _videos[index],
          rank: index + 1,
          onDownload: () => _downloadVideo(_videos[index]),
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
    final profileImg = _channelInfo!['profile_image_url'] as String? ?? '';
    final description = _channelInfo!['description'] as String? ?? '';
    final viewCount = _channelInfo!['view_count'] as int? ??
        _channelInfo!['subscriber_count'] as int? ??
        0;

    return Column(
      children: [
        // Channel info card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                if (profileImg.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(40),
                    child: Image.network(profileImg,
                        width: 64, height: 64, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.person, size: 64)),
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
                      Text(
                        '${_formatCount(viewCount)} total views  ·  $_platform',
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: _isLoadingVods ? null : _fetchVods,
                  icon: const Icon(Icons.video_library, size: 18),
                  label: Text(_isLoadingVods ? 'Loading...' : 'View VODs'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // VOD grid below
        if (_isLoadingVods)
          const Expanded(
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_vods.isNotEmpty)
          Expanded(child: _buildVodGrid(theme))
        else
          const Expanded(
            child: Center(
              child: Text('Click "View VODs" to load content.',
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
        child: Text('No VODs found for this channel.',
            style: TextStyle(color: Colors.white38)),
      );
    }
    return _buildVodGrid(theme);
  }

  Widget _buildVodGrid(ThemeData theme) {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 340,
        childAspectRatio: 16 / 11,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: _vods.length,
      itemBuilder: (context, index) {
        final vod = _vods[index];
        final vodId =
            vod['vod_id'] as String? ?? vod['video_id'] as String? ?? '';
        final title = vod['title'] as String? ?? 'Untitled';
        final thumbnail = vod['thumbnail_url'] as String? ?? '';
        final viewCount = vod['view_count'] as int? ?? 0;
        final duration = vod['duration'] as String? ?? '';
        final createdAt = vod['created_at'] as String? ?? '';

        return Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _fetchClips(vodId, title),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Thumbnail
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
                      // Duration badge
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
                      // Play overlay
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
                    ],
                  ),
                ),
                // Info
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
                          if (createdAt.isNotEmpty) ...[
                            const Text(' · ',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.white24)),
                            Text(_formatDate(createdAt),
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.white38)),
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
              label: const Text('Back to VODs'),
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

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                // Thumbnail
                if (thumbnail.isNotEmpty)
                  ClipRRect(
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
                        ],
                      ),
                    ),
                  ),
                if (thumbnail.isNotEmpty) const SizedBox(width: 12),
                // Clip info
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
                // Actions
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
                    IconButton(
                      icon: const Icon(Icons.link, size: 18),
                      tooltip: 'Copy URL',
                      onPressed: () {
                        final url = clip['url'] as String? ?? '';
                        if (url.isNotEmpty) {
                          Clipboard.setData(ClipboardData(text: url));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('URL copied to clipboard'),
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

// ── Trending Video Card ──

class _TrendingVideoCard extends StatelessWidget {
  final Map<String, dynamic> video;
  final int rank;
  final VoidCallback onDownload;

  const _TrendingVideoCard({
    required this.video,
    required this.rank,
    required this.onDownload,
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
            // Thumbnail
            if (thumbnailUrl.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 120,
                  height: 68,
                  child: Image.network(thumbnailUrl, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                          color: Colors.white10,
                          child: const Icon(Icons.broken_image,
                              size: 24, color: Colors.white24))),
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
                      _StatChip(Icons.visibility, _formatCount(views)),
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
            // Download + Copy
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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
                              content: Text('URL copied to clipboard'),
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

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String value;
  const _StatChip(this.icon, this.value);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: Colors.white38),
        const SizedBox(width: 4),
        Text(value,
            style: const TextStyle(fontSize: 11, color: Colors.white54)),
      ],
    );
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
