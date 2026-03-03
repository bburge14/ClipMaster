import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ipc/ipc_client.dart';
import '../../../core/ipc/ipc_message.dart';
import '../../../core/services/api_key_service.dart';

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

  @override
  void dispose() {
    _horizontalScroll.dispose();
    super.dispose();
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

  Future<void> _downloadVideo() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
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

  bool get _isBusy =>
      _isImporting || _isGeneratingProxy || _isTranscribing || _isGeneratingTts;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Top bar: video preview + controls
        Expanded(
          flex: 3,
          child: Container(
            color: const Color(0xFF0A0A14),
            child: _importedVideoPath == null
                ? _buildEmptyPreview()
                : _buildVideoInfo(),
          ),
        ),
        const Divider(height: 1),
        // Timeline controls
        _buildTimelineToolbar(),
        const Divider(height: 1),
        // Progress bar (when busy)
        if (_isBusy)
          Container(
            color: const Color(0xFF1E1E2E),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
          child: Container(
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
                                    _buildTrackRow(const Color(0xFF5A2D82)),
                                    _buildTrackRow(
                                      const Color(0xFF2D824A),
                                      hasClip: _ttsAudioPath != null,
                                      clipLabel: _ttsAudioPath != null
                                          ? 'TTS Audio'
                                          : null,
                                    ),
                                    _buildTrackRow(
                                      const Color(0xFF82782D),
                                      hasClip: _transcriptSegments.isNotEmpty,
                                      clipLabel:
                                          _transcriptSegments.isNotEmpty
                                              ? '${_transcriptSegments.length} captions'
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
          ),
        ),
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
            'Import a video to get started',
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

  Widget _buildVideoInfo() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.videocam, color: Color(0xFF6C5CE7), size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _importedVideoName ?? 'Video',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Action buttons
              _ActionButton(
                icon: Icons.folder_open,
                label: 'Replace',
                onPressed: _isBusy ? null : _importVideo,
              ),
              const SizedBox(width: 8),
              _ActionButton(
                icon: Icons.download,
                label: 'Download',
                onPressed: _isBusy ? null : _downloadVideo,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _importedVideoPath ?? '',
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withOpacity(0.3),
              fontFamily: 'monospace',
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),
          // Quick-action chips
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildActionChip(
                icon: Icons.high_quality,
                label: _proxyPath != null ? 'Proxy Ready' : 'Generate Proxy',
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
          ),
          // Show transcript preview if available
          if (_transcriptSegments.isNotEmpty) ...[
            const SizedBox(height: 16),
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
                  final start = (seg['start'] as num?)?.toDouble() ?? 0;
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
          ],
        ],
      ),
    );
  }

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

  Widget _buildTimelineToolbar() {
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
                    style: const TextStyle(fontSize: 10, color: Colors.white70),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
            : const SizedBox.expand(),
      ),
    );
  }
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
