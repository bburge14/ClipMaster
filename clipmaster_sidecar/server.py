"""FastAPI + WebSocket server for the ClipMaster sidecar.

Handles all IPC communication with the Flutter frontend.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from .models.ipc_models import IpcMessage, MessageType
from .services.script_analyzer import ScriptAnalyzer
from .services.viral_scout import ViralScout

logger = logging.getLogger("clipmaster_sidecar.server")


def create_app() -> FastAPI:
    app = FastAPI(title="ClipMaster Sidecar", version="1.0.0")
    script_analyzer = ScriptAnalyzer()
    viral_scout = ViralScout()

    @app.websocket("/ws")
    async def websocket_endpoint(ws: WebSocket) -> None:
        await ws.accept()
        logger.info("Flutter client connected.")

        try:
            while True:
                raw = await ws.receive_text()
                msg = IpcMessage.model_validate_json(raw)
                logger.info("Received [%s] id=%s", msg.type.value, msg.id)

                # Dispatch to the correct handler.
                asyncio.create_task(_dispatch(ws, msg, script_analyzer, viral_scout))
        except WebSocketDisconnect:
            logger.info("Flutter client disconnected.")

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    return app


async def _dispatch(
    ws: WebSocket,
    msg: IpcMessage,
    script_analyzer: ScriptAnalyzer,
    viral_scout: ViralScout,
) -> None:
    """Route an incoming IPC message to the correct service handler."""
    try:
        match msg.type:
            case MessageType.ping:
                await _send(ws, IpcMessage(id=msg.id, type=MessageType.pong, payload={}))

            case MessageType.analyze_script:
                await _handle_analyze_script(ws, msg, script_analyzer)

            case MessageType.scout_trending:
                await _handle_scout_trending(ws, msg, viral_scout)

            case MessageType.download_video:
                await _handle_download_video(ws, msg)

            case MessageType.generate_proxy:
                await _handle_generate_proxy(ws, msg)

            case MessageType.transcribe:
                await _handle_transcribe(ws, msg)

            case MessageType.ffmpeg_render:
                await _handle_ffmpeg_render(ws, msg)

            case _:
                await _send(
                    ws,
                    IpcMessage.error(msg.id, f"Unknown message type: {msg.type.value}"),
                )
    except Exception as exc:
        logger.exception("Error handling %s", msg.type.value)
        await _send(ws, IpcMessage.error(msg.id, str(exc)))


async def _send(ws: WebSocket, msg: IpcMessage) -> None:
    await ws.send_text(msg.to_json_str())


async def _handle_analyze_script(
    ws: WebSocket, msg: IpcMessage, analyzer: ScriptAnalyzer
) -> None:
    script_text = msg.payload.get("script", "")
    block_duration = msg.payload.get("block_duration_seconds", 5)

    await _send(ws, IpcMessage.progress(msg.id, "Analyzing script", 10))
    result = analyzer.analyze(script_text, block_duration_seconds=block_duration)
    await _send(ws, IpcMessage.progress(msg.id, "Analyzing script", 100))
    await _send(ws, IpcMessage.result(msg.id, {"visual_map": result}))


async def _handle_scout_trending(
    ws: WebSocket, msg: IpcMessage, scout: ViralScout
) -> None:
    platform = msg.payload.get("platform", "youtube")
    limit = msg.payload.get("limit", 20)

    await _send(ws, IpcMessage.progress(msg.id, "Scouting trending", 10))
    results = await scout.fetch_trending(platform=platform, limit=limit)
    await _send(ws, IpcMessage.progress(msg.id, "Scouting trending", 100))
    await _send(ws, IpcMessage.result(msg.id, {"videos": results}))


async def _handle_download_video(ws: WebSocket, msg: IpcMessage) -> None:
    """Placeholder: triggers yt-dlp download with progress reporting."""
    url = msg.payload.get("url", "")
    output_dir = msg.payload.get("output_dir", "./downloads")

    await _send(ws, IpcMessage.progress(msg.id, "Downloading", 0, f"URL: {url}"))
    # Actual yt-dlp subprocess integration would go here.
    await _send(
        ws,
        IpcMessage.result(
            msg.id, {"status": "placeholder", "message": "Download handler not yet wired."}
        ),
    )


async def _handle_generate_proxy(ws: WebSocket, msg: IpcMessage) -> None:
    """Placeholder: generates a 720p proxy from a 4K source using FFmpeg."""
    source = msg.payload.get("source_path", "")
    await _send(ws, IpcMessage.progress(msg.id, "Generating proxy", 0))
    await _send(
        ws,
        IpcMessage.result(
            msg.id, {"status": "placeholder", "message": "Proxy generation not yet wired."}
        ),
    )


async def _handle_transcribe(ws: WebSocket, msg: IpcMessage) -> None:
    """Placeholder: runs Faster-Whisper transcription with progress."""
    audio_path = msg.payload.get("audio_path", "")
    await _send(ws, IpcMessage.progress(msg.id, "Transcribing", 0))
    await _send(
        ws,
        IpcMessage.result(
            msg.id, {"status": "placeholder", "message": "Transcription not yet wired."}
        ),
    )


async def _handle_ffmpeg_render(ws: WebSocket, msg: IpcMessage) -> None:
    """Placeholder: FFmpeg render with h264_nvenc hardware acceleration."""
    await _send(ws, IpcMessage.progress(msg.id, "Rendering", 0))
    await _send(
        ws,
        IpcMessage.result(
            msg.id, {"status": "placeholder", "message": "FFmpeg render not yet wired."}
        ),
    )
