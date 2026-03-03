import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/ipc/ipc_client.dart';
import '../../../core/ipc/ipc_message.dart';

class ViralScoutPage extends ConsumerStatefulWidget {
  const ViralScoutPage({super.key});

  @override
  ConsumerState<ViralScoutPage> createState() => _ViralScoutPageState();
}

class _ViralScoutPageState extends ConsumerState<ViralScoutPage> {
  String _platform = 'youtube';
  String _searchQuery = '';
  bool _isLoading = false;
  String _progressStage = '';
  int _progressPercent = 0;
  List<Map<String, dynamic>> _videos = [];
  String? _error;

  List<Map<String, dynamic>> get _filteredVideos {
    if (_searchQuery.isEmpty) return _videos;
    final q = _searchQuery.toLowerCase();
    return _videos.where((v) {
      final title = (v['title'] as String? ?? '').toLowerCase();
      final channel = (v['channel'] as String? ?? '').toLowerCase();
      return title.contains(q) || channel.contains(q);
    }).toList();
  }

  Future<void> _fetchTrending() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _progressStage = 'Starting';
      _progressPercent = 0;
    });

    try {
      final ipc = ref.read(ipcClientProvider);
      final response = await ipc.send(
        IpcMessage(
          type: MessageType.scoutTrending,
          payload: {'platform': _platform, 'limit': 20},
        ),
        // yt-dlp can take a while to scrape trending videos.
        timeout: const Duration(seconds: 120),
        onProgress: (progress) {
          setState(() {
            _progressStage =
                progress.payload['stage'] as String? ?? 'Scouting';
            _progressPercent = progress.payload['percent'] as int? ?? 0;
          });
        },
      );

      if (response.type == MessageType.error) {
        setState(() {
          _isLoading = false;
          _error = response.payload['message'] as String? ?? 'Unknown error';
        });
      } else {
        final videoList =
            (response.payload['videos'] as List<dynamic>? ?? [])
                .cast<Map<String, dynamic>>();
        setState(() {
          _isLoading = false;
          _videos = videoList;
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
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
              const Icon(Icons.trending_up, size: 28, color: Color(0xFF6C5CE7)),
              const SizedBox(width: 12),
              Text('Viral Scout', style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
              )),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Discover trending videos ranked by viral clip potential.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white.withOpacity(0.4),
            ),
          ),
          const SizedBox(height: 20),
          // Controls row
          Row(
            children: [
              DropdownButton<String>(
                value: _platform,
                items: const [
                  DropdownMenuItem(value: 'youtube', child: Text('YouTube')),
                  DropdownMenuItem(value: 'twitch', child: Text('Twitch')),
                ],
                onChanged: (p) => setState(() => _platform = p!),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 250,
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Filter by title or channel...',
                    prefixIcon: Icon(Icons.search, size: 20),
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  onChanged: (q) => setState(() => _searchQuery = q),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _isLoading ? null : _fetchTrending,
                icon: const Icon(Icons.trending_up, size: 18),
                label: const Text('Scout Trending'),
              ),
              if (_videos.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  '${_filteredVideos.length} videos',
                  style: const TextStyle(fontSize: 12, color: Colors.white38),
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
              onPressed: _fetchTrending,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final videos = _filteredVideos;
    if (videos.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.trending_up, size: 64, color: Colors.white24),
            const SizedBox(height: 16),
            Text(
              _videos.isEmpty
                  ? 'Click "Scout Trending" to discover viral videos.'
                  : 'No videos match your filter.',
              style: const TextStyle(color: Colors.white38, fontSize: 15),
            ),
            if (_videos.isEmpty) ...[
              const SizedBox(height: 8),
              const Text(
                'Videos will be ranked by velocity and engagement density.',
                style: TextStyle(color: Colors.white24, fontSize: 12),
              ),
            ],
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: videos.length,
      itemBuilder: (context, index) {
        return _VideoCard(video: videos[index], rank: index + 1);
      },
    );
  }
}

class _VideoCard extends StatelessWidget {
  final Map<String, dynamic> video;
  final int rank;

  const _VideoCard({required this.video, required this.rank});

  @override
  Widget build(BuildContext context) {
    final title = video['title'] as String? ?? 'Untitled';
    final channel = video['channel'] as String? ?? 'Unknown';
    final platform = video['platform'] as String? ?? '';
    final views = video['views'] as int? ?? 0;
    final likes = video['likes'] as int? ?? 0;
    final comments = video['comments'] as int? ?? 0;
    final velocity = (video['velocity_score'] as num?)?.toDouble() ?? 0.0;
    final engagement =
        (video['engagement_density'] as num?)?.toDouble() ?? 0.0;
    final composite =
        (video['composite_score'] as num?)?.toDouble() ?? 0.0;
    final url = video['url'] as String? ?? '';

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
              child: Text(
                '#$rank',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: rank <= 3 ? const Color(0xFF6C5CE7) : Colors.white54,
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Video info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$channel  ·  ${platform.toUpperCase()}',
                    style:
                        const TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                  const SizedBox(height: 8),
                  // Stats row
                  Row(
                    children: [
                      _StatChip(Icons.visibility, _formatCount(views)),
                      const SizedBox(width: 8),
                      _StatChip(Icons.thumb_up_outlined, _formatCount(likes)),
                      const SizedBox(width: 8),
                      _StatChip(Icons.comment_outlined, _formatCount(comments)),
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
                _ScoreBadge(
                  'Velocity',
                  _formatVelocity(velocity),
                  Colors.lightBlueAccent,
                ),
                const SizedBox(height: 4),
                _ScoreBadge(
                  'Engage',
                  '${(engagement * 100).toStringAsFixed(1)}%',
                  Colors.orange,
                ),
                const SizedBox(height: 4),
                _ScoreBadge(
                  'Score',
                  composite.toStringAsFixed(2),
                  const Color(0xFF6C5CE7),
                ),
              ],
            ),
            const SizedBox(width: 8),
            // Copy URL button
            IconButton(
              icon: const Icon(Icons.link, size: 20),
              tooltip: 'Copy video URL',
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
        Text(value, style: const TextStyle(fontSize: 11, color: Colors.white54)),
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
          Text(
            '$label: ',
            style: TextStyle(fontSize: 10, color: color.withOpacity(0.7)),
          ),
          Text(
            value,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.bold, color: color),
          ),
        ],
      ),
    );
  }
}
