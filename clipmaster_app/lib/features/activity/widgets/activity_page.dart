import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/activity_service.dart';
import '../../../core/services/project_state.dart';
import '../../../main.dart';
import 'media_browser.dart';

/// Activity page — split view: task tracker (left) + media library (right).
class ActivityPage extends ConsumerWidget {
  const ActivityPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(activityProvider);
    final theme = Theme.of(context);

    final running = tasks.where((t) => t.isRunning).toList();
    final completed = tasks.where((t) => t.isCompleted).toList();
    final failed = tasks.where((t) => t.isFailed).toList();

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                  Icons.downloading, size: 28, color: Color(0xFF6C5CE7)),
              const SizedBox(width: 12),
              Text(
                'Activity',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (tasks.isNotEmpty)
                TextButton.icon(
                  onPressed: () {
                    ref.read(activityProvider.notifier).markAllSeen();
                  },
                  icon: const Icon(Icons.done_all, size: 16),
                  label: const Text('Mark all read'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Track downloads, renders, uploads, and browse your media library.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white.withOpacity(0.4),
            ),
          ),
          const SizedBox(height: 20),
          // Split view: Tasks | Media Library
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left: Task list
                Expanded(
                  flex: 1,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.task_alt,
                              size: 16, color: Colors.white54),
                          const SizedBox(width: 6),
                          const Text('Tasks',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white54)),
                          const Spacer(),
                          if (running.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.lightBlueAccent.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '${running.length} active',
                                style: const TextStyle(
                                    fontSize: 10,
                                    color: Colors.lightBlueAccent),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: tasks.isEmpty
                            ? _buildEmptyState()
                            : ListView(
                                children: [
                                  if (running.isNotEmpty) ...[
                                    _SectionHeader(
                                      'Running',
                                      count: running.length,
                                      color: Colors.lightBlueAccent,
                                    ),
                                    ...running
                                        .map((t) => _TaskTile(task: t)),
                                    const SizedBox(height: 16),
                                  ],
                                  if (completed.isNotEmpty) ...[
                                    _SectionHeader(
                                      'Completed',
                                      count: completed.length,
                                      color: Colors.greenAccent,
                                    ),
                                    ...completed
                                        .map((t) => _TaskTile(task: t)),
                                    const SizedBox(height: 16),
                                  ],
                                  if (failed.isNotEmpty) ...[
                                    _SectionHeader(
                                      'Failed',
                                      count: failed.length,
                                      color: Colors.redAccent,
                                    ),
                                    ...failed
                                        .map((t) => _TaskTile(task: t)),
                                  ],
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Container(
                  width: 1,
                  color: Colors.white.withOpacity(0.06),
                ),
                const SizedBox(width: 16),
                // Right: Media Library
                const Expanded(
                  flex: 1,
                  child: MediaBrowser(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_outlined, size: 48, color: Colors.white24),
          SizedBox(height: 12),
          Text(
            'No background tasks yet.',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
          SizedBox(height: 6),
          Text(
            'Downloads, renders, and uploads\nwill appear here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white24, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _SectionHeader(this.label,
      {required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration:
                BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            '$label ($count)',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskTile extends ConsumerWidget {
  final BackgroundTask task;

  const _TaskTile({required this.task});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categoryIcon = switch (task.category) {
      TaskCategory.download => Icons.download,
      TaskCategory.render => Icons.movie_creation,
      TaskCategory.upload => Icons.upload,
      TaskCategory.tts => Icons.record_voice_over,
    };

    final statusColor = switch (task.status) {
      TaskStatus.running => Colors.lightBlueAccent,
      TaskStatus.completed => Colors.greenAccent,
      TaskStatus.failed => Colors.redAccent,
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: task.isCompleted
            ? () => _loadInTimeline(ref, context)
            : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Category icon
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(categoryIcon, size: 20, color: statusColor),
              ),
              const SizedBox(width: 12),
              // Task info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                              color: task.hasBeenSeen
                                  ? Colors.white54
                                  : Colors.white,
                            ),
                          ),
                        ),
                        if (!task.hasBeenSeen && !task.isRunning)
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Color(0xFF6C5CE7),
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (task.subtitle != null)
                      Text(
                        task.subtitle!,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white38,
                        ),
                      ),
                    if (task.isRunning) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: task.percent / 100,
                                backgroundColor: Colors.white10,
                                valueColor:
                                    AlwaysStoppedAnimation(statusColor),
                                minHeight: 4,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${task.percent}%',
                            style: TextStyle(
                              fontSize: 11,
                              color: statusColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        task.stage,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white38,
                        ),
                      ),
                    ],
                    if (task.isFailed && task.error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          task.error!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.redAccent,
                          ),
                        ),
                      ),
                    if (task.isCompleted)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          task.resultPath != null
                              ? 'Saved: ${task.resultPath}'
                              : 'Done',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.greenAccent,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Actions
              if (task.isCompleted) ...[
                IconButton(
                  icon: const Icon(Icons.movie_creation_outlined,
                      size: 18),
                  tooltip: 'Load in Timeline',
                  onPressed: () => _loadInTimeline(ref, context),
                ),
              ],
              if (!task.isRunning)
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: 'Remove',
                  color: Colors.white24,
                  onPressed: () {
                    ref
                        .read(activityProvider.notifier)
                        .removeTask(task.id);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _loadInTimeline(WidgetRef ref, BuildContext context) {
    ref.read(activityProvider.notifier).markSeen(task.id);

    final title = task.title;
    final filePath = task.resultPath;
    final thumbnailUrl = task.metadata['thumbnail_url'] as String?;
    final url = task.metadata['url'] as String?;

    ref.read(projectProvider.notifier).addAsset(
          TimelineAsset(
            id: 'activity_${task.id}',
            track: TimelineTrack.video,
            label: title,
            filePath: filePath,
            url: url,
            thumbnailUrl: thumbnailUrl,
            metadata: task.metadata,
          ),
        );

    // Switch to Timeline tab.
    ref.read(selectedTabProvider.notifier).state = 0;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Loaded "$title" into Timeline'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
