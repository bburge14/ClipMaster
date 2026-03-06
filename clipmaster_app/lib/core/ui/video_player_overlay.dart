import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../ipc/ipc_client.dart';
import '../ipc/ipc_message.dart';

/// Full-screen overlay video player that plays URLs or local files.
///
/// For YouTube/Twitch URLs, resolves the direct stream URL via the sidecar
/// before playing. Falls back to direct playback for other URLs and local files.
///
/// Usage:
/// ```dart
/// VideoPlayerOverlay.show(context, url: 'https://...', title: 'Video');
/// ```
class VideoPlayerOverlay extends ConsumerStatefulWidget {
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
  ConsumerState<VideoPlayerOverlay> createState() => _VideoPlayerOverlayState();
}

class _VideoPlayerOverlayState extends ConsumerState<VideoPlayerOverlay> {
  Player? _player;
  VideoController? _controller;
  bool _isResolving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    final url = widget.url;

    // YouTube and Twitch URLs need stream URL resolution via yt-dlp
    final needsResolve = url.contains('youtube.com/') ||
        url.contains('youtu.be/') ||
        url.contains('twitch.tv/');

    String playUrl = url;

    if (needsResolve) {
      setState(() => _isResolving = true);

      try {
        final ipc = ref.read(ipcClientProvider);
        if (ipc.isConnected) {
          final response = await ipc.send(
            IpcMessage(
              type: MessageType.resolveStreamUrl,
              payload: {'url': url},
            ),
            timeout: const Duration(seconds: 25),
          );

          if (!mounted) return;

          if (response.type == MessageType.error) {
            setState(() {
              _isResolving = false;
              _error = response.payload['message'] as String? ??
                  'Failed to resolve video URL';
            });
            return;
          }

          playUrl = response.payload['stream_url'] as String? ?? url;
        }
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _isResolving = false;
          _error = 'Could not resolve video stream: $e';
        });
        return;
      }

      if (!mounted) return;
      setState(() => _isResolving = false);
    }

    final player = Player();
    final controller = VideoController(player);

    // Listen for errors
    player.stream.error.listen((error) {
      if (mounted && error.isNotEmpty) {
        setState(() => _error = 'Playback error: $error');
      }
    });

    if (!mounted) {
      player.dispose();
      return;
    }

    setState(() {
      _player = player;
      _controller = controller;
    });

    player.open(Media(playUrl));
  }

  @override
  void dispose() {
    _player?.dispose();
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
                child: _buildContent(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_isResolving) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFF6C5CE7)),
            SizedBox(height: 16),
            Text('Resolving video stream...',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                _error!,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  setState(() {
                    _error = null;
                    _player?.dispose();
                    _player = null;
                    _controller = null;
                  });
                  _initPlayer();
                },
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_controller == null) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF6C5CE7)),
      );
    }

    return Video(
      controller: _controller!,
      controls: MaterialVideoControls,
    );
  }
}
