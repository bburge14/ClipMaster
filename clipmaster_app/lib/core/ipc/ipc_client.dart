import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'ipc_message.dart';

final _log = Logger(printer: PrettyPrinter(methodCount: 0));

/// Manages the WebSocket connection to the Python sidecar process.
///
/// Responsibilities:
///   1. Launch the sidecar process (or connect to a running one).
///   2. Maintain the WebSocket link with auto-reconnect.
///   3. Route incoming messages to the correct completer/stream.
class IpcClient {
  static const int defaultPort = 9120;
  static const Duration _reconnectDelay = Duration(seconds: 2);
  static const int _maxReconnectAttempts = 5;

  WebSocketChannel? _channel;
  Process? _sidecarProcess;
  int _reconnectAttempts = 0;
  bool _disposed = false;

  /// Pending one-shot request -> response futures keyed by message id.
  final Map<String, Completer<IpcMessage>> _pendingRequests = {};

  /// Stream controllers for progress updates keyed by original request id.
  final Map<String, StreamController<IpcMessage>> _progressStreams = {};

  /// Global stream of all incoming messages (for the Dev Console).
  final StreamController<IpcMessage> _globalStream =
      StreamController.broadcast();

  Stream<IpcMessage> get messages => _globalStream.stream;

  /// Start the Python sidecar and connect via WebSocket.
  Future<void> start({String? pythonPath, int port = defaultPort}) async {
    final python = pythonPath ?? _resolveVenvPython() ?? 'python';
    final workDir = _resolveSidecarDir().replaceAll(
      Platform.isWindows ? '\\clipmaster_sidecar' : '/clipmaster_sidecar',
      '',
    );
    _log.i('Starting sidecar: $python -m clipmaster_sidecar --port $port');
    _log.i('Working directory: $workDir');

    _sidecarProcess = await Process.start(
      python,
      ['-m', 'clipmaster_sidecar', '--port', '$port'],
      workingDirectory: workDir,
    );

    // Pipe sidecar stdout/stderr to dev console logger.
    _sidecarProcess!.stdout.transform(const SystemEncoding().decoder).listen(
          (line) => _log.d('[sidecar:stdout] $line'),
        );
    _sidecarProcess!.stderr.transform(const SystemEncoding().decoder).listen(
          (line) => _log.w('[sidecar:stderr] $line'),
        );

    // Give the server a moment to bind.
    await Future.delayed(const Duration(seconds: 2));
    await _connect(port);
  }

  Future<void> _connect(int port) async {
    try {
      final uri = Uri.parse('ws://127.0.0.1:$port/ws');
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;
      _reconnectAttempts = 0;
      _log.i('WebSocket connected to $uri');

      _channel!.stream.listen(
        _onData,
        onError: (error) => _handleDisconnect(port, error),
        onDone: () => _handleDisconnect(port, null),
      );
    } catch (e) {
      _log.e('WebSocket connection failed: $e');
      await _reconnect(port);
    }
  }

  void _onData(dynamic raw) {
    try {
      final msg = IpcMessage.fromJson(raw as String);
      _globalStream.add(msg);

      if (msg.type == MessageType.progress) {
        _progressStreams[msg.id]?.add(msg);
      } else if (msg.type == MessageType.result ||
          msg.type == MessageType.error) {
        _pendingRequests.remove(msg.id)?.complete(msg);
        _progressStreams.remove(msg.id)?.close();
      }
    } catch (e) {
      _log.e('Failed to parse IPC message: $e');
    }
  }

  Future<void> _handleDisconnect(int port, Object? error) async {
    if (_disposed) return;
    _log.w('WebSocket disconnected: $error');
    await _reconnect(port);
  }

  Future<void> _reconnect(int port) async {
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      _log.e('Max reconnect attempts reached. Sidecar unreachable.');
      return;
    }
    _reconnectAttempts++;
    _log.i('Reconnecting (attempt $_reconnectAttempts)...');
    await Future.delayed(_reconnectDelay * _reconnectAttempts);
    await _connect(port);
  }

  /// Whether the WebSocket channel is currently connected.
  bool get isConnected => _channel != null && !_disposed;

  /// Send a request and get a [Future] for the one-shot response.
  /// Returns a [Stream] of progress messages via [onProgress].
  ///
  /// Throws [StateError] immediately if the sidecar is not connected.
  /// Times out after [timeout] (default 60 s) so the UI never hangs.
  Future<IpcMessage> send(
    IpcMessage request, {
    void Function(IpcMessage progress)? onProgress,
    Duration timeout = const Duration(seconds: 60),
  }) {
    if (_channel == null || _disposed) {
      return Future.error(
        StateError(
          'Sidecar is not connected. '
          'Check the Dev Console for startup errors.',
        ),
      );
    }

    final completer = Completer<IpcMessage>();
    _pendingRequests[request.id] = completer;

    if (onProgress != null) {
      final sc = StreamController<IpcMessage>();
      sc.stream.listen(onProgress);
      _progressStreams[request.id] = sc;
    }

    _channel?.sink.add(request.toJson());

    return completer.future.timeout(timeout, onTimeout: () {
      _pendingRequests.remove(request.id);
      _progressStreams.remove(request.id)?.close();
      throw TimeoutException(
        'Sidecar did not respond within ${timeout.inSeconds}s. '
        'Is the Python sidecar running?',
      );
    });
  }

  /// Resolve the path to the clipmaster_sidecar directory relative to the app.
  String _resolveSidecarDir() {
    final sep = Platform.pathSeparator;
    // In dev: adjacent directory.
    final devPath = '${Directory.current.path}${sep}clipmaster_sidecar';
    if (Directory(devPath).existsSync()) return devPath;

    // In production: bundled alongside the executable.
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return '$exeDir${sep}clipmaster_sidecar';
  }

  /// Find the Python executable.
  /// Search order:
  ///   1. Embedded python_runtime/ (installed .exe distribution)
  ///   2. .venv/ (dev mode via setup.bat/setup.sh)
  ///   3. null (falls back to system PATH 'python')
  String? _resolveVenvPython() {
    final sep = Platform.pathSeparator;
    final exeDir = File(Platform.resolvedExecutable).parent.path;

    // 1. Embedded Python runtime (from the installer build).
    //    This is what end-users have — no Python install needed.
    final embeddedPython = '$exeDir${sep}python_runtime${sep}python.exe';
    if (File(embeddedPython).existsSync()) {
      _log.i('Using embedded Python: $embeddedPython');
      return embeddedPython;
    }

    // 2. Dev .venv relative to project root.
    final devVenv = Platform.isWindows
        ? '${Directory.current.path}${sep}.venv${sep}Scripts${sep}python.exe'
        : '${Directory.current.path}${sep}.venv${sep}bin${sep}python';
    if (File(devVenv).existsSync()) {
      _log.i('Using venv Python: $devVenv');
      return devVenv;
    }

    // 3. Production .venv next to the executable.
    final prodVenv = Platform.isWindows
        ? '$exeDir${sep}.venv${sep}Scripts${sep}python.exe'
        : '$exeDir${sep}.venv${sep}bin${sep}python';
    if (File(prodVenv).existsSync()) {
      _log.i('Using venv Python: $prodVenv');
      return prodVenv;
    }

    _log.w('No bundled Python found. Falling back to system Python.');
    return null;
  }

  Future<void> dispose() async {
    _disposed = true;
    await _channel?.sink.close();
    _sidecarProcess?.kill();
    await _globalStream.close();
    for (final sc in _progressStreams.values) {
      await sc.close();
    }
  }
}

/// Riverpod provider for the singleton IPC client.
final ipcClientProvider = Provider<IpcClient>((ref) {
  final client = IpcClient();
  ref.onDispose(() => client.dispose());
  return client;
});
