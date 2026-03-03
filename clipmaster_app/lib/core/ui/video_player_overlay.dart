import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Full-screen overlay video player that plays URLs or local files.
///
/// Usage:
/// ```dart
/// VideoPlayerOverlay.show(context, url: 'https://...', title: 'Video');
/// ```
class VideoPlayerOverlay extends StatefulWidget {
  final String url;
  final String title;

  const VideoPlayerOverlay({
    super.key,
    required this.url,
    required this.title,
  });

  /// Show the player as a modal overlay.
  static void show(BuildContext context,
      {required String url, String title = ''}) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => VideoPlayerOverlay(url: url, title: title),
    );
  }

  @override
  State<VideoPlayerOverlay> createState() => _VideoPlayerOverlayState();
}

class _VideoPlayerOverlayState extends State<VideoPlayerOverlay> {
  late final Player _player;
  late final VideoController _controller;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _player.open(Media(widget.url));
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(40),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          color: const Color(0xFF141420),
          constraints: const BoxConstraints(
            maxWidth: 1100,
            maxHeight: 700,
          ),
          child: Column(
            children: [
              // Title bar
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                color: const Color(0xFF1E1E2E),
                child: Row(
                  children: [
                    const Icon(Icons.play_circle_outline,
                        size: 20, color: Color(0xFF6C5CE7)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.title.isNotEmpty ? widget.title : 'Video Player',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.of(context).pop(),
                      tooltip: 'Close',
                    ),
                  ],
                ),
              ),
              // Video area
              Expanded(
                child: Video(
                  controller: _controller,
                  controls: MaterialVideoControls,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
