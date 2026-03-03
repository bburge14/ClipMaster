import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Voice options for OpenAI TTS.
enum TtsVoice {
  alloy('Alloy', 'Neutral and balanced'),
  echo('Echo', 'Warm, conversational'),
  fable('Fable', 'Expressive, storytelling'),
  onyx('Onyx', 'Deep, authoritative'),
  nova('Nova', 'Friendly, upbeat'),
  shimmer('Shimmer', 'Clear, bright');

  final String label;
  final String description;
  const TtsVoice(this.label, this.description);
}

/// A clip/asset that lives on the timeline.
class TimelineAsset {
  final String id;
  final TimelineTrack track;
  final String label;
  final String? filePath;
  final String? url;
  final String? thumbnailUrl;
  final double startSec;
  final double durationSec;
  final Map<String, dynamic> metadata;

  TimelineAsset({
    required this.id,
    required this.track,
    required this.label,
    this.filePath,
    this.url,
    this.thumbnailUrl,
    this.startSec = 0,
    this.durationSec = 0,
    Map<String, dynamic>? metadata,
  }) : metadata = metadata ?? {};

  TimelineAsset copyWith({
    String? label,
    String? filePath,
    String? url,
    String? thumbnailUrl,
    double? startSec,
    double? durationSec,
    Map<String, dynamic>? metadata,
  }) {
    return TimelineAsset(
      id: id,
      track: track,
      label: label ?? this.label,
      filePath: filePath ?? this.filePath,
      url: url ?? this.url,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      startSec: startSec ?? this.startSec,
      durationSec: durationSec ?? this.durationSec,
      metadata: metadata ?? this.metadata,
    );
  }
}

enum TimelineTrack { video, broll, audio, captions, crops }

/// Caption styling options.
class CaptionStyle {
  final String fontFamily;
  final double fontSize;
  final int colorHex;
  final int bgColorHex;
  final bool hasBorder;

  const CaptionStyle({
    this.fontFamily = 'Inter',
    this.fontSize = 36,
    this.colorHex = 0xFFFFFFFF,
    this.bgColorHex = 0x00000000,
    this.hasBorder = true,
  });

  CaptionStyle copyWith({
    String? fontFamily,
    double? fontSize,
    int? colorHex,
    int? bgColorHex,
    bool? hasBorder,
  }) {
    return CaptionStyle(
      fontFamily: fontFamily ?? this.fontFamily,
      fontSize: fontSize ?? this.fontSize,
      colorHex: colorHex ?? this.colorHex,
      bgColorHex: bgColorHex ?? this.bgColorHex,
      hasBorder: hasBorder ?? this.hasBorder,
    );
  }
}

/// Shared project state accessible by all pages.
class ProjectState {
  final List<TimelineAsset> assets;
  final TtsVoice selectedVoice;
  final CaptionStyle captionStyle;
  final String? scriptText;
  final String? scriptTitle;

  const ProjectState({
    this.assets = const [],
    this.selectedVoice = TtsVoice.onyx,
    this.captionStyle = const CaptionStyle(),
    this.scriptText,
    this.scriptTitle,
  });

  ProjectState copyWith({
    List<TimelineAsset>? assets,
    TtsVoice? selectedVoice,
    CaptionStyle? captionStyle,
    String? scriptText,
    String? scriptTitle,
  }) {
    return ProjectState(
      assets: assets ?? this.assets,
      selectedVoice: selectedVoice ?? this.selectedVoice,
      captionStyle: captionStyle ?? this.captionStyle,
      scriptText: scriptText ?? this.scriptText,
      scriptTitle: scriptTitle ?? this.scriptTitle,
    );
  }
}

class ProjectNotifier extends StateNotifier<ProjectState> {
  ProjectNotifier() : super(const ProjectState());

  void addAsset(TimelineAsset asset) {
    state = state.copyWith(assets: [...state.assets, asset]);
  }

  void removeAsset(String id) {
    state = state.copyWith(
      assets: state.assets.where((a) => a.id != id).toList(),
    );
  }

  void updateAsset(String id, TimelineAsset Function(TimelineAsset) updater) {
    state = state.copyWith(
      assets: state.assets.map((a) => a.id == id ? updater(a) : a).toList(),
    );
  }

  void setVoice(TtsVoice voice) {
    state = state.copyWith(selectedVoice: voice);
  }

  void setCaptionStyle(CaptionStyle style) {
    state = state.copyWith(captionStyle: style);
  }

  void setScript({String? text, String? title}) {
    state = state.copyWith(scriptText: text, scriptTitle: title);
  }

  void clear() {
    state = const ProjectState();
  }

  /// Load a short into the timeline (called from Fact Shorts "Edit in Timeline").
  void loadShortIntoTimeline({
    required String title,
    required String scriptText,
    required TtsVoice voice,
    String? ttsAudioPath,
    String? bgVideoPath,
    List<Map<String, dynamic>> stockClips = const [],
  }) {
    final assets = <TimelineAsset>[];
    int idCounter = 0;

    if (bgVideoPath != null) {
      assets.add(TimelineAsset(
        id: 'asset_${idCounter++}',
        track: TimelineTrack.video,
        label: 'Background',
        filePath: bgVideoPath,
      ));
    }

    if (ttsAudioPath != null) {
      assets.add(TimelineAsset(
        id: 'asset_${idCounter++}',
        track: TimelineTrack.audio,
        label: 'Voiceover ($voice)',
        filePath: ttsAudioPath,
      ));
    }

    for (final clip in stockClips) {
      assets.add(TimelineAsset(
        id: 'asset_${idCounter++}',
        track: TimelineTrack.broll,
        label: clip['keyword'] as String? ?? 'B-Roll',
        url: clip['download_url'] as String?,
        thumbnailUrl: clip['preview_url'] as String?,
        metadata: clip,
      ));
    }

    state = state.copyWith(
      assets: assets,
      selectedVoice: voice,
      scriptText: scriptText,
      scriptTitle: title,
    );
  }
}

final projectProvider =
    StateNotifierProvider<ProjectNotifier, ProjectState>((ref) {
  return ProjectNotifier();
});
