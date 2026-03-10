import 'package:flutter/material.dart';

/// A drag handle between two panels. Supports horizontal (column resize)
/// and vertical (row resize) dragging.
class ResizableDivider extends StatefulWidget {
  /// Whether the divider is horizontal (dragged left/right) or vertical
  /// (dragged up/down).
  final Axis axis;

  /// Called with the drag delta in logical pixels.
  final ValueChanged<double> onDragUpdate;

  const ResizableDivider({
    super.key,
    required this.axis,
    required this.onDragUpdate,
  });

  @override
  State<ResizableDivider> createState() => _ResizableDividerState();
}

class _ResizableDividerState extends State<ResizableDivider> {
  bool _hovering = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final isVertical = widget.axis == Axis.vertical;
    final cursor = isVertical
        ? SystemMouseCursors.resizeRow
        : SystemMouseCursors.resizeColumn;

    final highlight = _hovering || _dragging;

    return MouseRegion(
      cursor: cursor,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: isVertical
            ? (d) => widget.onDragUpdate(d.delta.dy)
            : null,
        onVerticalDragStart: isVertical
            ? (_) => setState(() => _dragging = true)
            : null,
        onVerticalDragEnd: isVertical
            ? (_) => setState(() => _dragging = false)
            : null,
        onHorizontalDragUpdate: !isVertical
            ? (d) => widget.onDragUpdate(d.delta.dx)
            : null,
        onHorizontalDragStart: !isVertical
            ? (_) => setState(() => _dragging = true)
            : null,
        onHorizontalDragEnd: !isVertical
            ? (_) => setState(() => _dragging = false)
            : null,
        child: Container(
          width: isVertical ? double.infinity : 5,
          height: isVertical ? 5 : double.infinity,
          color: highlight
              ? const Color(0xFF6C5CE7).withOpacity(0.5)
              : const Color(0xFF1A1A2A),
        ),
      ),
    );
  }
}
