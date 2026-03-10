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
  final double speed; // 0.25x – 4.0x playback speed
  final bool visible;
  final bool locked;
  final double volume; // 0.0 – 1.0 for audio-bearing assets
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
    this.speed = 1.0,
    this.visible = true,
    this.locked = false,
    this.volume = 1.0,
    Map<String, dynamic>? metadata,
  }) : metadata = metadata ?? {};

  TimelineAsset copyWith({
    String? label,
    String? filePath,
    String? url,
    String? thumbnailUrl,
    double? startSec,
    double? durationSec,
    double? speed,
    bool? visible,
    bool? locked,
    double? volume,
    TimelineTrack? track,
    Map<String, dynamic>? metadata,
  }) {
    return TimelineAsset(
      id: id,
      track: track ?? this.track,
      label: label ?? this.label,
      filePath: filePath ?? this.filePath,
      url: url ?? this.url,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      startSec: startSec ?? this.startSec,
      durationSec: durationSec ?? this.durationSec,
      speed: speed ?? this.speed,
      visible: visible ?? this.visible,
      locked: locked ?? this.locked,
      volume: volume ?? this.volume,
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
  final bool isBold;
  final bool isItalic;

  /// Text position within the 9:16 frame (0.0 – 1.0 normalised).
  final double positionX;
  final double positionY;

  /// Text box size (0.0 – 1.0 normalised, null = auto-fit).
  final double? boxWidth;
  final double? boxHeight;

  const CaptionStyle({
    this.fontFamily = 'Inter',
    this.fontSize = 36,
    this.colorHex = 0xFFFFFFFF,
    this.bgColorHex = 0x00000000,
    this.hasBorder = true,
    this.isBold = true,
    this.isItalic = false,
    this.positionX = 0.5,
    this.positionY = 0.75,
    this.boxWidth,
    this.boxHeight,
  });

  CaptionStyle copyWith({
    String? fontFamily,
    double? fontSize,
    int? colorHex,
    int? bgColorHex,
    bool? hasBorder,
    bool? isBold,
    bool? isItalic,
    double? positionX,
    double? positionY,
    double? boxWidth,
    double? boxHeight,
    bool clearBoxSize = false,
  }) {
    return CaptionStyle(
      fontFamily: fontFamily ?? this.fontFamily,
      fontSize: fontSize ?? this.fontSize,
      colorHex: colorHex ?? this.colorHex,
      bgColorHex: bgColorHex ?? this.bgColorHex,
      hasBorder: hasBorder ?? this.hasBorder,
      isBold: isBold ?? this.isBold,
      isItalic: isItalic ?? this.isItalic,
      positionX: positionX ?? this.positionX,
      positionY: positionY ?? this.positionY,
      boxWidth: clearBoxSize ? null : (boxWidth ?? this.boxWidth),
      boxHeight: clearBoxSize ? null : (boxHeight ?? this.boxHeight),
    );
  }
}

/// Shared project state accessible by all pages.
class ProjectState {
  final List<TimelineAsset> assets;
  final TtsVoice selectedVoice;
  final CaptionStyle captionStyle;
  final CaptionStyle titleStyle;
  final String? scriptText;
  final String? scriptTitle;

  const ProjectState({
    this.assets = const [],
    this.selectedVoice = TtsVoice.onyx,
    this.captionStyle = const CaptionStyle(),
    this.titleStyle = const CaptionStyle(
      fontSize: 42,
      positionX: 0.5,
      positionY: 0.08,
    ),
    this.scriptText,
    this.scriptTitle,
  });

  ProjectState copyWith({
    List<TimelineAsset>? assets,
    TtsVoice? selectedVoice,
    CaptionStyle? captionStyle,
    CaptionStyle? titleStyle,
    String? scriptText,
    String? scriptTitle,
  }) {
    return ProjectState(
      assets: assets ?? this.assets,
      selectedVoice: selectedVoice ?? this.selectedVoice,
      captionStyle: captionStyle ?? this.captionStyle,
      titleStyle: titleStyle ?? this.titleStyle,
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

  void reorderAsset(String id, int newIndex) {
    final list = [...state.assets];
    final oldIndex = list.indexWhere((a) => a.id == id);
    if (oldIndex < 0 || oldIndex == newIndex) return;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex.clamp(0, list.length), item);
    state = state.copyWith(assets: list);
  }

  void moveAssetToTrack(String id, TimelineTrack track) {
    updateAsset(id, (a) => a.copyWith(track: track));
  }

  void setVoice(TtsVoice voice) {
    state = state.copyWith(selectedVoice: voice);
  }

  void setCaptionStyle(CaptionStyle style) {
    state = state.copyWith(captionStyle: style);
  }

  void setTitleStyle(CaptionStyle style) {
    state = state.copyWith(titleStyle: style);
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
    String? bgPreviewUrl,
    String? bgDownloadUrl,
    CaptionStyle? captionStyle,
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
    } else if (bgPreviewUrl != null && bgPreviewUrl.isNotEmpty) {
      // Use the stock footage URL the user selected in the composer
      assets.add(TimelineAsset(
        id: 'asset_${idCounter++}',
        track: TimelineTrack.video,
        label: 'Background',
        url: bgDownloadUrl ?? bgPreviewUrl,
        thumbnailUrl: bgPreviewUrl,
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
      captionStyle: captionStyle ?? const CaptionStyle(),
      scriptText: scriptText,
      scriptTitle: title,
    );
  }
}

final projectProvider =
    StateNotifierProvider<ProjectNotifier, ProjectState>((ref) {
  return ProjectNotifier();
});
