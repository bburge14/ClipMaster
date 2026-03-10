"""Tests for the IPC message models."""

from __future__ import annotations

import json

from clipmaster_sidecar.models.ipc_models import IpcMessage, MessageType


def test_message_types_exist() -> None:
    """All documented message types should be defined."""
    expected = [
        "ping", "pong", "downloadVideo", "downloadClip", "generateProxy",
        "transcribe", "generateTts", "analyzeScript", "queryStockFootage",
        "scoutTrending", "generateFacts", "ffmpegRender", "createShort",
        "progress", "result", "error",
    ]
    for t in expected:
        assert MessageType(t), f"Missing message type: {t}"


def test_ipc_message_progress() -> None:
    msg = IpcMessage.progress("req-123", "Downloading", 50, detail="50%")
    assert msg.id == "req-123"
    assert msg.type == MessageType.progress
    assert msg.payload["stage"] == "Downloading"
    assert msg.payload["percent"] == 50
    assert msg.payload["detail"] == "50%"


def test_ipc_message_progress_without_detail() -> None:
    msg = IpcMessage.progress("req-456", "Processing", 75)
    assert "detail" not in msg.payload


def test_ipc_message_result() -> None:
    msg = IpcMessage.result("req-789", {"output_path": "/tmp/video.mp4"})
    assert msg.id == "req-789"
    assert msg.type == MessageType.result
    assert msg.payload["output_path"] == "/tmp/video.mp4"


def test_ipc_message_error() -> None:
    msg = IpcMessage.error("req-000", "Something broke", code="ERR_001")
    assert msg.id == "req-000"
    assert msg.type == MessageType.error
    assert msg.payload["message"] == "Something broke"
    assert msg.payload["code"] == "ERR_001"


def test_ipc_message_error_without_code() -> None:
    msg = IpcMessage.error("req-001", "Oops")
    assert "code" not in msg.payload


def test_ipc_message_serialization() -> None:
    msg = IpcMessage(
        id="test-id",
        type=MessageType.ping,
        payload={"hello": "world"},
    )
    json_str = msg.to_json_str()
    data = json.loads(json_str)
    assert data["id"] == "test-id"
    assert data["type"] == "ping"
    assert data["payload"]["hello"] == "world"
    assert "timestamp" in data


def test_ipc_message_deserialization() -> None:
    raw = json.dumps({
        "id": "test-id",
        "type": "ping",
        "payload": {},
        "timestamp": "2026-03-10T12:00:00",
    })
    msg = IpcMessage.model_validate_json(raw)
    assert msg.id == "test-id"
    assert msg.type == MessageType.ping


def test_ipc_message_auto_id() -> None:
    msg1 = IpcMessage(type=MessageType.ping, payload={})
    msg2 = IpcMessage(type=MessageType.ping, payload={})
    assert msg1.id != msg2.id  # UUIDs should be unique
