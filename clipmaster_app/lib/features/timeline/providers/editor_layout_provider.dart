import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Panels that can be toggled on/off and resized in the editor.
enum EditorPanel {
  leftSidebar,
  rightSidebar,
  timeline,
  toolbar, // The action toolbar (Stock Footage, Layers, etc.)
}

/// Which sub-tab is active in the left sidebar.
enum LeftSidebarTab {
  stockFootage,
  layers,
  textEditor,
  voicePicker,
  assetProperties,
}

/// Which content is showing in the right sidebar.
enum RightSidebarContent {
  script,
  aiCreate,
}

class EditorLayoutState {
  final Map<EditorPanel, bool> panelVisible;
  final Map<EditorPanel, double> panelSizes;
  final LeftSidebarTab leftTab;
  final RightSidebarContent rightContent;

  const EditorLayoutState({
    required this.panelVisible,
    required this.panelSizes,
    this.leftTab = LeftSidebarTab.layers,
    this.rightContent = RightSidebarContent.script,
  });

  factory EditorLayoutState.initial() {
    return const EditorLayoutState(
      panelVisible: {
        EditorPanel.leftSidebar: false,
        EditorPanel.rightSidebar: true,
        EditorPanel.timeline: true,
        EditorPanel.toolbar: true,
      },
      panelSizes: {
        EditorPanel.leftSidebar: 300.0,
        EditorPanel.rightSidebar: 340.0,
        EditorPanel.timeline: 280.0,
      },
    );
  }

  EditorLayoutState copyWith({
    Map<EditorPanel, bool>? panelVisible,
    Map<EditorPanel, double>? panelSizes,
    LeftSidebarTab? leftTab,
    RightSidebarContent? rightContent,
  }) {
    return EditorLayoutState(
      panelVisible: panelVisible ?? this.panelVisible,
      panelSizes: panelSizes ?? this.panelSizes,
      leftTab: leftTab ?? this.leftTab,
      rightContent: rightContent ?? this.rightContent,
    );
  }

  bool isPanelVisible(EditorPanel panel) => panelVisible[panel] ?? false;
  double panelSize(EditorPanel panel) => panelSizes[panel] ?? 300.0;
}

/// Min/max constraints for resizable panels.
class PanelConstraints {
  static const double leftSidebarMin = 200.0;
  static const double leftSidebarMax = 500.0;
  static const double rightSidebarMin = 280.0;
  static const double rightSidebarMax = 600.0;
  static const double timelineMin = 150.0;
  static const double timelineMax = 500.0;
  static const double previewMinHeight = 200.0;
  static const double previewMaxHeight = 800.0;

  static double minFor(EditorPanel panel) => switch (panel) {
        EditorPanel.leftSidebar => leftSidebarMin,
        EditorPanel.rightSidebar => rightSidebarMin,
        EditorPanel.timeline => timelineMin,
        EditorPanel.toolbar => 0,
      };

  static double maxFor(EditorPanel panel) => switch (panel) {
        EditorPanel.leftSidebar => leftSidebarMax,
        EditorPanel.rightSidebar => rightSidebarMax,
        EditorPanel.timeline => timelineMax,
        EditorPanel.toolbar => 0,
      };
}

class EditorLayoutNotifier extends StateNotifier<EditorLayoutState> {
  EditorLayoutNotifier() : super(EditorLayoutState.initial());

  void togglePanel(EditorPanel panel) {
    final current = state.panelVisible[panel] ?? false;
    state = state.copyWith(
      panelVisible: {...state.panelVisible, panel: !current},
    );
  }

  void setPanelVisible(EditorPanel panel, bool visible) {
    state = state.copyWith(
      panelVisible: {...state.panelVisible, panel: visible},
    );
  }

  void resizePanel(EditorPanel panel, double delta) {
    final current = state.panelSizes[panel] ?? 300.0;
    final min = PanelConstraints.minFor(panel);
    final max = PanelConstraints.maxFor(panel);
    final newSize = (current + delta).clamp(min, max);
    state = state.copyWith(
      panelSizes: {...state.panelSizes, panel: newSize},
    );
  }

  void setLeftTab(LeftSidebarTab tab) {
    // Opening a tab also makes the sidebar visible
    state = state.copyWith(
      leftTab: tab,
      panelVisible: {...state.panelVisible, EditorPanel.leftSidebar: true},
    );
  }

  void setRightContent(RightSidebarContent content) {
    state = state.copyWith(
      rightContent: content,
      panelVisible: {...state.panelVisible, EditorPanel.rightSidebar: true},
    );
  }
}

final editorLayoutProvider =
    StateNotifierProvider<EditorLayoutNotifier, EditorLayoutState>(
  (ref) => EditorLayoutNotifier(),
);
