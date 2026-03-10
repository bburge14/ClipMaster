import 'package:flutter/material.dart';

/// Editor tool mode (select, razor, hand).
enum EditorTool { select, razor, hand }

/// Professional toolbar replacing the floating action chips.
class EditorToolbar extends StatelessWidget {
  final VoidCallback onImportFile;
  final VoidCallback onDownloadUrl;
  final VoidCallback onRender;
  final VoidCallback onGenerateProxy;
  final VoidCallback onTranscribe;
  final VoidCallback onSplitAtPlayhead;
  final VoidCallback onDuplicate;
  final VoidCallback onDeleteSelected;
  final EditorTool activeTool;
  final ValueChanged<EditorTool> onToolChanged;
  final bool snapEnabled;
  final VoidCallback onToggleSnap;
  final bool hasSelection;
  final bool hasVideo;
  final bool hasScript;
  final bool hasProxy;
  final bool hasTranscript;
  final bool isBusy;
  final bool isRendering;

  const EditorToolbar({
    super.key,
    required this.onImportFile,
    required this.onDownloadUrl,
    required this.onRender,
    required this.onGenerateProxy,
    required this.onTranscribe,
    required this.onSplitAtPlayhead,
    required this.onDuplicate,
    required this.onDeleteSelected,
    required this.activeTool,
    required this.onToolChanged,
    required this.snapEnabled,
    required this.onToggleSnap,
    required this.hasSelection,
    required this.hasVideo,
    required this.hasScript,
    required this.hasProxy,
    required this.hasTranscript,
    required this.isBusy,
    required this.isRendering,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      color: const Color(0xFF16161F),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          // Import section
          _ToolbarIconButton(
            icon: Icons.folder_open,
            tooltip: 'Import File',
            onPressed: isBusy ? null : onImportFile,
          ),
          _ToolbarIconButton(
            icon: Icons.download,
            tooltip: 'Download URL',
            onPressed: isBusy ? null : onDownloadUrl,
          ),
          _divider(),

          // Video processing
          if (hasVideo) ...[
            _ToolbarIconButton(
              icon: Icons.high_quality,
              tooltip: hasProxy ? 'Proxy Ready' : 'Generate Proxy',
              onPressed: isBusy || hasProxy ? null : onGenerateProxy,
              activeColor:
                  hasProxy ? const Color(0xFF00C853) : null,
            ),
            _ToolbarIconButton(
              icon: Icons.subtitles,
              tooltip: hasTranscript ? 'Transcribed' : 'Transcribe',
              onPressed:
                  isBusy || hasTranscript ? null : onTranscribe,
              activeColor:
                  hasTranscript ? const Color(0xFF00C853) : null,
            ),
            _divider(),
          ],

          // Tool selection
          _ToolbarToggle(
            icon: Icons.near_me,
            tooltip: 'Select (V)',
            isActive: activeTool == EditorTool.select,
            onPressed: () => onToolChanged(EditorTool.select),
          ),
          _ToolbarToggle(
            icon: Icons.content_cut,
            tooltip: 'Razor (C)',
            isActive: activeTool == EditorTool.razor,
            onPressed: () => onToolChanged(EditorTool.razor),
          ),
          _ToolbarToggle(
            icon: Icons.pan_tool_alt,
            tooltip: 'Hand (H)',
            isActive: activeTool == EditorTool.hand,
            onPressed: () => onToolChanged(EditorTool.hand),
          ),
          _divider(),

          // Clip actions
          _ToolbarIconButton(
            icon: Icons.splitscreen,
            tooltip: 'Split at Playhead (S)',
            onPressed: hasSelection ? onSplitAtPlayhead : null,
          ),
          _ToolbarIconButton(
            icon: Icons.copy,
            tooltip: 'Duplicate (Ctrl+D)',
            onPressed: hasSelection ? onDuplicate : null,
          ),
          _ToolbarIconButton(
            icon: Icons.delete_outline,
            tooltip: 'Delete (Del)',
            onPressed: hasSelection ? onDeleteSelected : null,
          ),
          _divider(),

          // Snap
          _ToolbarToggle(
            icon: Icons.grid_on,
            tooltip: 'Snap to Grid',
            isActive: snapEnabled,
            onPressed: onToggleSnap,
            label: 'Snap',
          ),

          const Spacer(),

          // Render button
          if (hasScript)
            _RenderButton(
              onPressed: isBusy ? null : onRender,
              isRendering: isRendering,
            ),
        ],
      ),
    );
  }

  Widget _divider() {
    return Container(
      width: 1,
      height: 22,
      color: Colors.white10,
      margin: const EdgeInsets.symmetric(horizontal: 6),
    );
  }
}

class _ToolbarIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? activeColor;

  const _ToolbarIconButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final color = activeColor ??
        (onPressed != null ? Colors.white54 : Colors.white.withOpacity(0.2));
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          width: 30,
          height: 30,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          child: Icon(icon, size: 17, color: color),
        ),
      ),
    );
  }
}

class _ToolbarToggle extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool isActive;
  final VoidCallback onPressed;
  final String? label;

  const _ToolbarToggle({
    required this.icon,
    required this.tooltip,
    required this.isActive,
    required this.onPressed,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          height: 28,
          padding: EdgeInsets.symmetric(horizontal: label != null ? 8 : 6),
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: isActive
                ? const Color(0xFF6C5CE7).withOpacity(0.25)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: isActive
                ? Border.all(color: const Color(0xFF6C5CE7).withOpacity(0.5))
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15,
                  color: isActive
                      ? const Color(0xFF6C5CE7)
                      : Colors.white38),
              if (label != null) ...[
                const SizedBox(width: 4),
                Text(
                  label!,
                  style: TextStyle(
                    fontSize: 11,
                    color: isActive
                        ? const Color(0xFF6C5CE7)
                        : Colors.white38,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RenderButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final bool isRendering;

  const _RenderButton({this.onPressed, this.isRendering = false});

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: isRendering
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.movie_creation, size: 16),
      label: Text(
        isRendering ? 'Rendering...' : 'Render Short',
        style: const TextStyle(fontSize: 12),
      ),
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF6C5CE7),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    );
  }
}
