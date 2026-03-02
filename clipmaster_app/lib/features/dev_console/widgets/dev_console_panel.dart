import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/dev_console.dart';

/// The Dev Console UI panel — a toggleable overlay that shows real-time
/// logs from all subsystems (FFmpeg, IPC, API calls, yt-dlp, etc.).
class DevConsolePanel extends ConsumerStatefulWidget {
  const DevConsolePanel({super.key});

  @override
  ConsumerState<DevConsolePanel> createState() => _DevConsolePanelState();
}

class _DevConsolePanelState extends ConsumerState<DevConsolePanel> {
  final ScrollController _scrollController = ScrollController();
  LogLevel _minLevel = LogLevel.debug;
  String? _sourceFilter;
  String _searchText = '';
  bool _autoScroll = true;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final console = ref.watch(devConsoleProvider);
    final theme = Theme.of(context);

    return Container(
      color: const Color(0xFF1E1E1E),
      child: Column(
        children: [
          // Toolbar
          _buildToolbar(console, theme),
          const Divider(height: 1, color: Colors.white24),
          // Log entries
          Expanded(
            child: StreamBuilder<DevLogEntry>(
              stream: console.stream,
              builder: (context, _) {
                final filtered = console.filter(
                  source: _sourceFilter,
                  minLevel: _minLevel,
                  searchText: _searchText.isNotEmpty ? _searchText : null,
                );

                if (_autoScroll) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (_scrollController.hasClients) {
                      _scrollController.jumpTo(
                        _scrollController.position.maxScrollExtent,
                      );
                    }
                  });
                }

                return ListView.builder(
                  controller: _scrollController,
                  itemCount: filtered.length,
                  padding: const EdgeInsets.all(8),
                  itemBuilder: (context, index) {
                    final entry = filtered[index];
                    return _buildLogLine(entry);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(DevConsole console, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          const Text(
            'DEV CONSOLE',
            style: TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.bold,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 16),
          // Level filter
          DropdownButton<LogLevel>(
            value: _minLevel,
            dropdownColor: const Color(0xFF2D2D2D),
            style: const TextStyle(color: Colors.white70, fontSize: 12),
            underline: const SizedBox(),
            items: LogLevel.values.map((level) {
              return DropdownMenuItem(
                value: level,
                child: Text(level.name.toUpperCase()),
              );
            }).toList(),
            onChanged: (level) => setState(() => _minLevel = level!),
          ),
          const SizedBox(width: 8),
          // Source filter
          DropdownButton<String?>(
            value: _sourceFilter,
            dropdownColor: const Color(0xFF2D2D2D),
            style: const TextStyle(color: Colors.white70, fontSize: 12),
            underline: const SizedBox(),
            hint: const Text('All Sources',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
            items: [
              const DropdownMenuItem(value: null, child: Text('All Sources')),
              ...console.sources.map((s) =>
                  DropdownMenuItem(value: s, child: Text(s))),
            ],
            onChanged: (source) => setState(() => _sourceFilter = source),
          ),
          const SizedBox(width: 8),
          // Search
          SizedBox(
            width: 200,
            height: 28,
            child: TextField(
              style: const TextStyle(color: Colors.white70, fontSize: 12),
              decoration: const InputDecoration(
                hintText: 'Search...',
                hintStyle: TextStyle(color: Colors.white24),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                border: OutlineInputBorder(),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
              ),
              onChanged: (text) => setState(() => _searchText = text),
            ),
          ),
          const Spacer(),
          // Auto-scroll toggle
          IconButton(
            icon: Icon(
              _autoScroll ? Icons.vertical_align_bottom : Icons.pause,
              color: Colors.white54,
              size: 18,
            ),
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
            tooltip: _autoScroll ? 'Pause auto-scroll' : 'Resume auto-scroll',
          ),
          // Clear
          IconButton(
            icon: const Icon(Icons.delete_outline,
                color: Colors.white54, size: 18),
            onPressed: () {
              console.clear();
              setState(() {});
            },
            tooltip: 'Clear console',
          ),
        ],
      ),
    );
  }

  Widget _buildLogLine(DevLogEntry entry) {
    final color = switch (entry.level) {
      LogLevel.debug => Colors.grey,
      LogLevel.info => Colors.lightBlueAccent,
      LogLevel.warning => Colors.orange,
      LogLevel.error => Colors.redAccent,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Text(
        entry.formatted,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: color,
        ),
      ),
    );
  }
}
