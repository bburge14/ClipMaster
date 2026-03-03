/// IPC Protocol Message Definitions for Flutter <-> Python Sidecar Communication.
///
/// Transport: WebSocket on localhost (default port 9120).
///
/// Protocol Overview:
///   Flutter sends a JSON "request" -> Python processes -> Python sends back
///   one or more JSON "response" messages (including real-time progress updates).
///
/// Message Envelope:
///   {
///     "id": "<uuid>",           // Unique message ID for request-response correlation
///     "type": "<MessageType>",  // The operation type
///     "payload": { ... },       // Type-specific data
///     "timestamp": "<ISO8601>"  // When the message was created
///   }
///
/// Progress updates share the same "id" as the originating request:
///   {
///     "id": "<original-request-uuid>",
///     "type": "progress",
///     "payload": {
///       "stage": "Transcribing",
///       "percent": 45,
///       "detail": "Processing segment 12/27"
///     }
///   }
library;

import 'dart:convert';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// All supported IPC message types between Flutter and Python sidecar.
enum MessageType {
  // -- Requests (Flutter -> Python) --
  ping,
  downloadVideo,
  generateProxy,
  transcribe,
  generateTts,
  analyzeScript,
  queryStockFootage,
  scoutTrending,
  generateFacts,
  ffmpegRender,
  createShort,

  // -- Responses (Python -> Flutter) --
  pong,
  progress,
  result,
  error,
}

/// The universal IPC message envelope.
class IpcMessage {
  final String id;
  final MessageType type;
  final Map<String, dynamic> payload;
  final DateTime timestamp;

  IpcMessage({
    String? id,
    required this.type,
    required this.payload,
    DateTime? timestamp,
  })  : id = id ?? _uuid.v4(),
        timestamp = timestamp ?? DateTime.now();

  factory IpcMessage.fromJson(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return IpcMessage(
      id: map['id'] as String,
      type: MessageType.values.byName(map['type'] as String),
      payload: map['payload'] as Map<String, dynamic>,
      timestamp: DateTime.parse(map['timestamp'] as String),
    );
  }

  String toJson() => jsonEncode({
        'id': id,
        'type': type.name,
        'payload': payload,
        'timestamp': timestamp.toIso8601String(),
      });

  /// Convenience: build a progress message tied to an existing request.
  static IpcMessage progress({
    required String requestId,
    required String stage,
    required int percent,
    String? detail,
  }) =>
      IpcMessage(
        id: requestId,
        type: MessageType.progress,
        payload: {
          'stage': stage,
          'percent': percent,
          if (detail != null) 'detail': detail,
        },
      );

  /// Convenience: build a result message tied to an existing request.
  static IpcMessage result({
    required String requestId,
    required Map<String, dynamic> data,
  }) =>
      IpcMessage(
        id: requestId,
        type: MessageType.result,
        payload: data,
      );

  /// Convenience: build an error message tied to an existing request.
  static IpcMessage error({
    required String requestId,
    required String message,
    String? code,
  }) =>
      IpcMessage(
        id: requestId,
        type: MessageType.error,
        payload: {
          'message': message,
          if (code != null) 'code': code,
        },
      );
}
