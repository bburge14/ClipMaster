"""Pydantic models mirroring the IPC protocol defined in the Flutter side."""

from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Any
from uuid import uuid4

from pydantic import BaseModel, Field


class MessageType(str, Enum):
    # Requests (Flutter -> Python)
    ping = "ping"
    download_video = "downloadVideo"
    download_clip = "downloadClip"
    generate_proxy = "generateProxy"
    transcribe = "transcribe"
    generate_tts = "generateTts"
    analyze_script = "analyzeScript"
    query_stock_footage = "queryStockFootage"
    scout_trending = "scoutTrending"
    scout_channel = "scoutChannel"
    scout_vods = "scoutVods"
    scout_clips = "scoutClips"
    resolve_stream_url = "resolveStreamUrl"
    generate_facts = "generateFacts"
    ffmpeg_render = "ffmpegRender"
    create_short = "createShort"
    preview_snapshot = "previewSnapshot"
    preview_video_clip = "previewVideoClip"

    # Responses (Python -> Flutter)
    pong = "pong"
    progress = "progress"
    result = "result"
    error = "error"


class IpcMessage(BaseModel):
    id: str = Field(default_factory=lambda: str(uuid4()))
    type: MessageType
    payload: dict[str, Any] = Field(default_factory=dict)
    timestamp: datetime = Field(default_factory=datetime.now)

    def to_json_str(self) -> str:
        return self.model_dump_json()

    @classmethod
    def progress(
        cls,
        request_id: str,
        stage: str,
        percent: int,
        detail: str | None = None,
    ) -> IpcMessage:
        payload: dict[str, Any] = {"stage": stage, "percent": percent}
        if detail:
            payload["detail"] = detail
        return cls(id=request_id, type=MessageType.progress, payload=payload)

    @classmethod
    def result(cls, request_id: str, data: dict[str, Any]) -> IpcMessage:
        return cls(id=request_id, type=MessageType.result, payload=data)

    @classmethod
    def error(cls, request_id: str, message: str, code: str | None = None) -> IpcMessage:
        payload: dict[str, Any] = {"message": message}
        if code:
            payload["code"] = code
        return cls(id=request_id, type=MessageType.error, payload=payload)
