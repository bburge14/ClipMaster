import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/services/project_state.dart';
import '../../../main.dart';

/// Scans the ClipMaster output directories and shows thumbnails / file names.
///
/// Folders scanned:
///   - Downloads (~/Downloads or app documents/downloads)
///   - Created Shorts (app documents/shorts)
///   - Renders (app documents/renders)
class MediaBrowser extends ConsumerStatefulWidget {
  const MediaBrowser({super.key});

  @override
  ConsumerState<MediaBrowser> createState() => _MediaBrowserState();
}

class _MediaBrowserState extends ConsumerState<MediaBrowser> {
  String _selectedFolder = 'downloads';
  List<FileSystemEntity> _files = [];
  bool _isScanning = false;
  String? _currentPath;

  static const _videoExtensions = {
    '.mp4', '.mkv', '.webm', '.mov', '.avi', '.flv', '.wmv', '.m4v',
  };

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<String> _getFolderPath(String folder) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final cmDir = Directory(p.join(docsDir.path, 'ClipMaster'));

    return switch (folder) {
      'downloads' => p.join(cmDir.path, 'downloads'),
      'shorts' => p.join(cmDir.path, 'shorts'),
      'renders' => p.join(cmDir.path, 'renders'),
      _ => p.join(cmDir.path, 'downloads'),
    };
  }

  Future<void> _scan() async {
    setState(() => _isScanning = true);
    try {
      final folderPath = await _getFolderPath(_selectedFolder);
      _currentPath = folderPath;
      final dir = Directory(folderPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
        setState(() {
          _files = [];
          _isScanning = false;
        });
        return;
      }
      final allFiles = await dir
          .list()
          .where((f) =>
              f is File &&
              _videoExtensions.contains(p.extension(f.path).toLowerCase()))
          .toList();
      // Sort by modified date, newest first.
      allFiles.sort((a, b) {
        final aStat = (a as File).statSync();
        final bStat = (b as File).statSync();
        return bStat.modified.compareTo(aStat.modified);
      });
      setState(() {
        _files = allFiles;
        _isScanning = false;
      });
    } catch (e) {
      setState(() {
        _files = [];
        _isScanning = false;
      });
    }
  }

  void _loadInTimeline(File file) {
    ref.read(projectProvider.notifier).addAsset(
          TimelineAsset(
            id: 'media_${file.path.hashCode}',
            track: TimelineTrack.video,
            label: p.basenameWithoutExtension(file.path),
            filePath: file.path,
          ),
        );
    ref.read(selectedTabProvider.notifier).state = 0;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            'Loaded "${p.basenameWithoutExtension(file.path)}" into Timeline'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Folder selector
        Row(
          children: [
            const Icon(Icons.folder_open, size: 20, color: Color(0xFF6C5CE7)),
            const SizedBox(width: 8),
            const Text('Media Library',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            const Spacer(),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'downloads', label: Text('Downloads')),
                ButtonSegment(value: 'shorts', label: Text('Shorts')),
                ButtonSegment(value: 'renders', label: Text('Renders')),
              ],
              selected: {_selectedFolder},
              onSelectionChanged: (val) {
                setState(() => _selectedFolder = val.first);
                _scan();
              },
              style: ButtonStyle(
                textStyle: WidgetStatePropertyAll(
                  const TextStyle(fontSize: 11),
                ),
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.refresh, size: 18),
              tooltip: 'Refresh',
              onPressed: _scan,
            ),
          ],
        ),
        if (_currentPath != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _currentPath!,
              style: const TextStyle(fontSize: 10, color: Colors.white24),
            ),
          ),
        const SizedBox(height: 12),
        // File grid
        Expanded(
          child: _isScanning
              ? const Center(child: CircularProgressIndicator())
              : _files.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.video_library_outlined,
                              size: 48, color: Colors.white24),
                          const SizedBox(height: 12),
                          Text(
                            'No videos in $_selectedFolder yet.',
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 13),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Downloaded and created videos will appear here.',
                            style:
                                TextStyle(color: Colors.white24, fontSize: 11),
                          ),
                        ],
                      ),
                    )
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 220,
                        childAspectRatio: 16 / 12,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                      ),
                      itemCount: _files.length,
                      itemBuilder: (context, index) {
                        final file = _files[index] as File;
                        return _VideoFileTile(
                          file: file,
                          onTap: () => _loadInTimeline(file),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

class _VideoFileTile extends StatelessWidget {
  final File file;
  final VoidCallback onTap;

  const _VideoFileTile({required this.file, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final name = p.basenameWithoutExtension(file.path);
    final ext = p.extension(file.path).toUpperCase().replaceFirst('.', '');
    final stat = file.statSync();
    final sizeInMb = stat.size / (1024 * 1024);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Preview area with play icon overlay
            Expanded(
              child: Container(
                width: double.infinity,
                color: Colors.white.withOpacity(0.04),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.movie,
                            size: 32, color: Colors.white24),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF6C5CE7).withOpacity(0.3),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(ext,
                              style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white70)),
                        ),
                      ],
                    ),
                    // Size badge
                    Positioned(
                      bottom: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          '${sizeInMb.toStringAsFixed(1)} MB',
                          style: const TextStyle(
                              fontSize: 9, color: Colors.white70),
                        ),
                      ),
                    ),
                    // "Load" overlay on hover
                    Positioned.fill(
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: onTap,
                          child: Container(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // File info
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    _formatDate(stat.modified),
                    style:
                        const TextStyle(fontSize: 10, color: Colors.white38),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays > 30) {
      return '${dt.month}/${dt.day}/${dt.year}';
    }
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    return '${diff.inMinutes}m ago';
  }
}
