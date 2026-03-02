import 'package:flutter/material.dart';

/// The Magnetic Timeline — the core editing UI for ClipMaster Pro.
///
/// Design philosophy:
///   - Non-destructive editing: Auto-Crop and Auto-Caption generate editable
///     objects on the timeline, never "baked-in" effects.
///   - Proxy playback: 720p proxies are used for scrubbing while the original
///     4K VODs are used for final rendering.
///   - Magnetic snapping: clips snap to adjacent edges for fast assembly.
class MagneticTimeline extends StatefulWidget {
  const MagneticTimeline({super.key});

  @override
  State<MagneticTimeline> createState() => _MagneticTimelineState();
}

class _MagneticTimelineState extends State<MagneticTimeline> {
  double _zoomLevel = 1.0;
  double _playheadPosition = 0.0;
  final ScrollController _horizontalScroll = ScrollController();

  @override
  void dispose() {
    _horizontalScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        // Top bar: video preview + controls
        Expanded(
          flex: 3,
          child: Container(
            color: Colors.black,
            child: const Center(
              child: Text(
                'Video Preview',
                style: TextStyle(color: Colors.white24, fontSize: 18),
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        // Timeline controls
        _buildTimelineToolbar(theme),
        const Divider(height: 1),
        // Timeline tracks
        Expanded(
          flex: 2,
          child: Container(
            color: const Color(0xFF1A1A2E),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Track labels + horizontal scrollable tracks
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
                                // Track rows
                                Column(
                                  children: [
                                    _buildTrackRow(const Color(0xFF2D5AA0)),
                                    _buildTrackRow(const Color(0xFF5A2D82)),
                                    _buildTrackRow(const Color(0xFF2D824A)),
                                    _buildTrackRow(const Color(0xFF82782D)),
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
          ),
        ),
      ],
    );
  }

  Widget _buildTimelineToolbar(ThemeData theme) {
    return Container(
      height: 40,
      color: const Color(0xFF16213E),
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
          // Magnetic snap toggle
          FilterChip(
            label: const Text('Magnetic Snap', style: TextStyle(fontSize: 11)),
            selected: true,
            onSelected: (_) {},
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Proxy Mode', style: TextStyle(fontSize: 11)),
            selected: true,
            onSelected: (_) {},
          ),
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

  Widget _buildTrackRow(Color color) {
    return Expanded(
      child: Container(
        decoration: BoxDecoration(
          border: const Border(bottom: BorderSide(color: Colors.white10)),
          color: color.withOpacity(0.1),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}
