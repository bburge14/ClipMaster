import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/editor_layout_provider.dart';

/// Professional menu bar (File | Edit | View | Help) for the editor.
class EditorMenuBar extends ConsumerWidget {
  final VoidCallback onImportFile;
  final VoidCallback onDownloadUrl;
  final VoidCallback onRender;
  final VoidCallback onSplitAtPlayhead;
  final VoidCallback onDuplicate;
  final VoidCallback onDeleteSelected;
  final VoidCallback onSelectAll;
  final bool hasSelection;
  final bool hasScript;
  final bool isBusy;

  const EditorMenuBar({
    super.key,
    required this.onImportFile,
    required this.onDownloadUrl,
    required this.onRender,
    required this.onSplitAtPlayhead,
    required this.onDuplicate,
    required this.onDeleteSelected,
    required this.onSelectAll,
    required this.hasSelection,
    required this.hasScript,
    required this.isBusy,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layout = ref.watch(editorLayoutProvider);
    final layoutNotifier = ref.read(editorLayoutProvider.notifier);

    return Container(
      height: 32,
      color: const Color(0xFF111118),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          // File menu
          _MenuButton(
            label: 'File',
            items: [
              _MenuItem(
                icon: Icons.folder_open,
                label: 'Import File',
                shortcut: 'Ctrl+I',
                onTap: onImportFile,
              ),
              _MenuItem(
                icon: Icons.download,
                label: 'Download URL',
                shortcut: 'Ctrl+U',
                onTap: onDownloadUrl,
              ),
              const _MenuDivider(),
              _MenuItem(
                icon: Icons.movie_creation,
                label: 'Export / Render Short',
                shortcut: 'Ctrl+E',
                onTap: hasScript && !isBusy ? onRender : null,
              ),
            ],
          ),
          // Edit menu
          _MenuButton(
            label: 'Edit',
            items: [
              _MenuItem(
                icon: Icons.splitscreen,
                label: 'Split at Playhead',
                shortcut: 'S',
                onTap: hasSelection ? onSplitAtPlayhead : null,
              ),
              _MenuItem(
                icon: Icons.copy,
                label: 'Duplicate',
                shortcut: 'Ctrl+D',
                onTap: hasSelection ? onDuplicate : null,
              ),
              _MenuItem(
                icon: Icons.delete_outline,
                label: 'Delete Selected',
                shortcut: 'Del',
                onTap: hasSelection ? onDeleteSelected : null,
              ),
              const _MenuDivider(),
              _MenuItem(
                icon: Icons.select_all,
                label: 'Select All',
                shortcut: 'Ctrl+A',
                onTap: onSelectAll,
              ),
            ],
          ),
          // View menu
          _MenuButton(
            label: 'View',
            items: [
              _MenuToggle(
                icon: Icons.movie_filter,
                label: 'Stock Footage',
                checked: layout.isPanelVisible(EditorPanel.leftSidebar) &&
                    layout.leftTab == LeftSidebarTab.stockFootage,
                onTap: () {
                  if (layout.isPanelVisible(EditorPanel.leftSidebar) &&
                      layout.leftTab == LeftSidebarTab.stockFootage) {
                    layoutNotifier.setPanelVisible(
                        EditorPanel.leftSidebar, false);
                  } else {
                    layoutNotifier.setLeftTab(LeftSidebarTab.stockFootage);
                  }
                },
              ),
              _MenuToggle(
                icon: Icons.layers,
                label: 'Layers',
                checked: layout.isPanelVisible(EditorPanel.leftSidebar) &&
                    layout.leftTab == LeftSidebarTab.layers,
                onTap: () {
                  if (layout.isPanelVisible(EditorPanel.leftSidebar) &&
                      layout.leftTab == LeftSidebarTab.layers) {
                    layoutNotifier.setPanelVisible(
                        EditorPanel.leftSidebar, false);
                  } else {
                    layoutNotifier.setLeftTab(LeftSidebarTab.layers);
                  }
                },
              ),
              _MenuToggle(
                icon: Icons.text_fields,
                label: 'Text / Font',
                checked: layout.isPanelVisible(EditorPanel.leftSidebar) &&
                    layout.leftTab == LeftSidebarTab.textEditor,
                onTap: () {
                  if (layout.isPanelVisible(EditorPanel.leftSidebar) &&
                      layout.leftTab == LeftSidebarTab.textEditor) {
                    layoutNotifier.setPanelVisible(
                        EditorPanel.leftSidebar, false);
                  } else {
                    layoutNotifier.setLeftTab(LeftSidebarTab.textEditor);
                  }
                },
              ),
              _MenuToggle(
                icon: Icons.record_voice_over,
                label: 'Voice',
                checked: layout.isPanelVisible(EditorPanel.leftSidebar) &&
                    layout.leftTab == LeftSidebarTab.voicePicker,
                onTap: () {
                  if (layout.isPanelVisible(EditorPanel.leftSidebar) &&
                      layout.leftTab == LeftSidebarTab.voicePicker) {
                    layoutNotifier.setPanelVisible(
                        EditorPanel.leftSidebar, false);
                  } else {
                    layoutNotifier.setLeftTab(LeftSidebarTab.voicePicker);
                  }
                },
              ),
              const _MenuDivider(),
              _MenuToggle(
                icon: Icons.description,
                label: 'Script Panel',
                checked: layout.isPanelVisible(EditorPanel.rightSidebar) &&
                    layout.rightContent == RightSidebarContent.script,
                onTap: () {
                  if (layout.isPanelVisible(EditorPanel.rightSidebar) &&
                      layout.rightContent == RightSidebarContent.script) {
                    layoutNotifier.setPanelVisible(
                        EditorPanel.rightSidebar, false);
                  } else {
                    layoutNotifier
                        .setRightContent(RightSidebarContent.script);
                  }
                },
              ),
              _MenuToggle(
                icon: Icons.auto_awesome,
                label: 'AI Create',
                checked: layout.isPanelVisible(EditorPanel.rightSidebar) &&
                    layout.rightContent == RightSidebarContent.aiCreate,
                onTap: () {
                  if (layout.isPanelVisible(EditorPanel.rightSidebar) &&
                      layout.rightContent == RightSidebarContent.aiCreate) {
                    layoutNotifier.setPanelVisible(
                        EditorPanel.rightSidebar, false);
                  } else {
                    layoutNotifier
                        .setRightContent(RightSidebarContent.aiCreate);
                  }
                },
              ),
              const _MenuDivider(),
              _MenuToggle(
                icon: Icons.view_timeline,
                label: 'Timeline',
                checked: layout.isPanelVisible(EditorPanel.timeline),
                onTap: () =>
                    layoutNotifier.togglePanel(EditorPanel.timeline),
              ),
            ],
          ),
          // Help menu
          _MenuButton(
            label: 'Help',
            items: [
              _MenuItem(
                icon: Icons.keyboard,
                label: 'Keyboard Shortcuts',
                onTap: () => _showShortcutsDialog(context),
              ),
              _MenuItem(
                icon: Icons.info_outline,
                label: 'About ClipMaster Pro',
                onTap: () => _showAboutDialog(context),
              ),
            ],
          ),
          const Spacer(),
        ],
      ),
    );
  }

  void _showShortcutsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Keyboard Shortcuts'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              _ShortcutRow('Play / Pause', 'Space'),
              _ShortcutRow('Select Tool', 'V'),
              _ShortcutRow('Razor Tool', 'C'),
              _ShortcutRow('Hand Tool', 'H'),
              _ShortcutRow('Split at Playhead', 'S'),
              _ShortcutRow('Duplicate', 'Ctrl+D'),
              _ShortcutRow('Delete Selected', 'Del'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showAboutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('ClipMaster Pro'),
        content: const Text(
          'Professional viral content creation suite.\n\nVersion 1.0.0',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

// ─── Menu building blocks ───

class _MenuButton extends StatelessWidget {
  final String label;
  final List<Widget> items;

  const _MenuButton({required this.label, required this.items});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<VoidCallback>(
      tooltip: '',
      offset: const Offset(0, 32),
      color: const Color(0xFF1E1E2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      onSelected: (callback) => callback(),
      itemBuilder: (context) {
        return items.map((item) {
          if (item is _MenuDivider) {
            return const PopupMenuDivider();
          } else if (item is _MenuItem) {
            return PopupMenuItem<VoidCallback>(
              enabled: item.onTap != null,
              value: item.onTap,
              height: 36,
              child: Row(
                children: [
                  Icon(item.icon, size: 16,
                      color: item.onTap != null
                          ? Colors.white54
                          : Colors.white24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      item.label,
                      style: TextStyle(
                        fontSize: 13,
                        color: item.onTap != null
                            ? Colors.white
                            : Colors.white38,
                      ),
                    ),
                  ),
                  if (item.shortcut != null)
                    Text(
                      item.shortcut!,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withOpacity(0.3),
                      ),
                    ),
                ],
              ),
            );
          } else if (item is _MenuToggle) {
            return PopupMenuItem<VoidCallback>(
              value: item.onTap,
              height: 36,
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    child: item.checked
                        ? const Icon(Icons.check, size: 16,
                            color: Color(0xFF6C5CE7))
                        : null,
                  ),
                  const SizedBox(width: 6),
                  Icon(item.icon, size: 16, color: Colors.white54),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      item.label,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            );
          }
          return const PopupMenuItem<VoidCallback>(
            value: null,
            child: SizedBox.shrink(),
          );
        }).cast<PopupMenuEntry<VoidCallback>>().toList();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: Colors.white.withOpacity(0.7),
          ),
        ),
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? shortcut;
  final VoidCallback? onTap;

  const _MenuItem({
    required this.icon,
    required this.label,
    this.shortcut,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _MenuToggle extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool checked;
  final VoidCallback onTap;

  const _MenuToggle({
    required this.icon,
    required this.label,
    required this.checked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _MenuDivider extends StatelessWidget {
  const _MenuDivider();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _ShortcutRow extends StatelessWidget {
  final String action;
  final String shortcut;

  const _ShortcutRow(this.action, this.shortcut);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(action,
                style: const TextStyle(fontSize: 13, color: Colors.white70)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            child: Text(
              shortcut,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: Colors.white.withOpacity(0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
