import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Status of a background task.
enum TaskStatus { running, completed, failed }

/// Category of background task.
enum TaskCategory { download, render, upload, tts }

/// A background task visible in the Activity tracker.
class BackgroundTask {
  final String id;
  final TaskCategory category;
  final String title;
  final String? subtitle;
  final DateTime startedAt;
  DateTime? completedAt;
  TaskStatus status;
  int percent;
  String stage;
  String? resultPath;
  String? error;

  /// Metadata from the originating source (e.g. video URL, thumbnail).
  final Map<String, dynamic> metadata;

  BackgroundTask({
    required this.id,
    required this.category,
    required this.title,
    this.subtitle,
    DateTime? startedAt,
    this.status = TaskStatus.running,
    this.percent = 0,
    this.stage = 'Starting',
    this.resultPath,
    this.error,
    Map<String, dynamic>? metadata,
  })  : startedAt = startedAt ?? DateTime.now(),
        metadata = metadata ?? {};

  bool get isRunning => status == TaskStatus.running;
  bool get isCompleted => status == TaskStatus.completed;
  bool get isFailed => status == TaskStatus.failed;

  /// How many unread completed tasks exist (for badge count).
  bool hasBeenSeen = false;
}

class ActivityNotifier extends StateNotifier<List<BackgroundTask>> {
  ActivityNotifier() : super([]);

  /// Add a new task and return its ID.
  String addTask({
    required String id,
    required TaskCategory category,
    required String title,
    String? subtitle,
    Map<String, dynamic>? metadata,
  }) {
    state = [
      BackgroundTask(
        id: id,
        category: category,
        title: title,
        subtitle: subtitle,
        metadata: metadata ?? {},
      ),
      ...state,
    ];
    return id;
  }

  void updateProgress(String id, {required int percent, required String stage}) {
    state = [
      for (final t in state)
        if (t.id == id) ...[t..percent = percent..stage = stage] else t,
    ];
  }

  void complete(String id, {String? resultPath}) {
    state = [
      for (final t in state)
        if (t.id == id)
          ...[
            t
              ..status = TaskStatus.completed
              ..percent = 100
              ..stage = 'Complete'
              ..completedAt = DateTime.now()
              ..resultPath = resultPath
          ]
        else
          t,
    ];
  }

  void fail(String id, String error) {
    state = [
      for (final t in state)
        if (t.id == id)
          ...[
            t
              ..status = TaskStatus.failed
              ..stage = 'Failed'
              ..completedAt = DateTime.now()
              ..error = error
          ]
        else
          t,
    ];
  }

  void markSeen(String id) {
    state = [
      for (final t in state)
        if (t.id == id) ...[t..hasBeenSeen = true] else t,
    ];
  }

  void markAllSeen() {
    for (final t in state) {
      t.hasBeenSeen = true;
    }
    state = [...state];
  }

  void removeTask(String id) {
    state = state.where((t) => t.id != id).toList();
  }

  int get unseenCount =>
      state.where((t) => !t.isRunning && !t.hasBeenSeen).length;

  int get runningCount => state.where((t) => t.isRunning).length;
}

final activityProvider =
    StateNotifierProvider<ActivityNotifier, List<BackgroundTask>>((ref) {
  return ActivityNotifier();
});
