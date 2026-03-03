"""FastAPI + WebSocket server for the ClipMaster sidecar.

Handles all IPC communication with the Flutter frontend.
"""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from .models.ipc_models import IpcMessage, MessageType
from .services.fact_generator import FactGenerator
from .services.llm_gateway import LlmGateway
from .services.media_tools import (
    download_video,
    ffmpeg_render,
    generate_proxy,
    generate_tts,
    transcribe_audio,
)
from .services.script_analyzer import ScriptAnalyzer
from .services.stock_footage import StockFootageService
from .services.viral_scout import ViralScout
from .services.youtube_search import YouTubeSearchService

logger = logging.getLogger("clipmaster_sidecar.server")


def create_app() -> FastAPI:
    app = FastAPI(title="ClipMaster Sidecar", version="1.0.0")
    script_analyzer = ScriptAnalyzer()
    viral_scout = ViralScout()
    llm_gateway = LlmGateway()
    fact_generator = FactGenerator(llm_gateway)
    stock_footage = StockFootageService()
    youtube_search = YouTubeSearchService()

    @app.websocket("/ws")
    async def websocket_endpoint(ws: WebSocket) -> None:
        await ws.accept()
        logger.info("Flutter client connected.")

        try:
            while True:
                raw = await ws.receive_text()
                try:
                    msg = IpcMessage.model_validate_json(raw)
                except Exception as exc:
                    logger.error("Invalid IPC message: %s", exc)
                    try:
                        raw_data = json.loads(raw)
                        msg_id = raw_data.get("id", "")
                        if msg_id:
                            err = IpcMessage.error(
                                msg_id,
                                f"Sidecar could not parse message: {exc}. "
                                "You may need to rebuild the app so the sidecar "
                                "and Flutter app versions match.",
                            )
                            await ws.send_text(err.to_json_str())
                    except Exception:
                        pass
                    continue
                logger.info("Received [%s] id=%s", msg.type.value, msg.id)

                asyncio.create_task(
                    _dispatch(
                        ws, msg, script_analyzer, viral_scout, fact_generator,
                        stock_footage, youtube_search,
                    )
                )
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
    fact_generator: FactGenerator,
    stock_footage: StockFootageService,
    youtube_search: YouTubeSearchService,
) -> None:
    """Route an incoming IPC message to the correct service handler."""
    try:
        match msg.type:
            case MessageType.ping:
                await _send(ws, IpcMessage(id=msg.id, type=MessageType.pong, payload={}))

            case MessageType.analyze_script:
                await _handle_analyze_script(ws, msg, script_analyzer)

            case MessageType.scout_trending:
                await _handle_scout_trending(ws, msg, viral_scout, youtube_search)

            case MessageType.generate_facts:
                await _handle_generate_facts(ws, msg, fact_generator)

            case MessageType.download_video:
                await _handle_download_video(ws, msg)

            case MessageType.generate_proxy:
                await _handle_generate_proxy(ws, msg)

            case MessageType.transcribe:
                await _handle_transcribe(ws, msg)

            case MessageType.ffmpeg_render:
                await _handle_ffmpeg_render(ws, msg)

            case MessageType.generate_tts:
                await _handle_generate_tts(ws, msg)

            case MessageType.query_stock_footage:
                await _handle_query_stock_footage(ws, msg, stock_footage)

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


# ---------------------------------------------------------------------------
# Analyze Script
# ---------------------------------------------------------------------------

async def _handle_analyze_script(
    ws: WebSocket, msg: IpcMessage, analyzer: ScriptAnalyzer
) -> None:
    script_text = msg.payload.get("script", "")
    block_duration = msg.payload.get("block_duration_seconds", 5)

    await _send(ws, IpcMessage.progress(msg.id, "Analyzing script", 10))
    result = analyzer.analyze(script_text, block_duration_seconds=block_duration)
    await _send(ws, IpcMessage.progress(msg.id, "Analyzing script", 100))
    await _send(ws, IpcMessage.result(msg.id, {"visual_map": result}))


# ---------------------------------------------------------------------------
# Viral Scout — YouTube Data API with yt-dlp fallback
# ---------------------------------------------------------------------------

async def _handle_scout_trending(
    ws: WebSocket,
    msg: IpcMessage,
    scout: ViralScout,
    youtube_search: YouTubeSearchService,
) -> None:
    platform = msg.payload.get("platform", "youtube")
    limit = msg.payload.get("limit", 20)
    api_key = msg.payload.get("api_key", "")
    query = msg.payload.get("query", "")

    if platform == "youtube" and api_key:
        # Use YouTube Data API (reliable, structured data).
        await _send(ws, IpcMessage.progress(msg.id, "Querying YouTube API", 10))
        try:
            if query:
                results = await youtube_search.search_videos(
                    api_key=api_key, query=query, limit=limit,
                )
            else:
                results = await youtube_search.search_trending(
                    api_key=api_key, limit=limit,
                )
            await _send(ws, IpcMessage.progress(msg.id, "Ranking results", 80))
            await _send(ws, IpcMessage.progress(msg.id, "Complete", 100))
            await _send(ws, IpcMessage.result(msg.id, {"videos": results}))
        except ValueError as exc:
            await _send(ws, IpcMessage.error(msg.id, str(exc)))
        return

    # Fallback: yt-dlp scraping (unreliable but doesn't require API key).
    await _send(ws, IpcMessage.progress(msg.id, "Finding yt-dlp", 5))
    ytdlp = scout._find_ytdlp()
    if not ytdlp:
        await _send(
            ws,
            IpcMessage.error(
                msg.id,
                "No YouTube API key provided and yt-dlp not found. "
                "Add a YouTube Data API key in Settings to use Viral Scout.",
            ),
        )
        return

    await _send(ws, IpcMessage.progress(msg.id, "Scraping trending page", 10))
    results = await scout.fetch_trending(platform=platform, limit=limit)
    await _send(ws, IpcMessage.progress(msg.id, "Complete", 100))
    await _send(ws, IpcMessage.result(msg.id, {"videos": results}))


# ---------------------------------------------------------------------------
# Fact Generation
# ---------------------------------------------------------------------------

async def _handle_generate_facts(
    ws: WebSocket, msg: IpcMessage, generator: FactGenerator
) -> None:
    category = msg.payload.get("category", "science")
    count = msg.payload.get("count", 5)
    provider = msg.payload.get("provider", "openai")
    api_key = msg.payload.get("api_key", "")

    if not api_key:
        await _send(
            ws,
            IpcMessage.error(msg.id, "No API key provided. Add one in API Key settings."),
        )
        return

    await _send(ws, IpcMessage.progress(msg.id, "Preparing prompt", 10))
    await _send(ws, IpcMessage.progress(msg.id, "Calling AI provider", 30))
    facts = await generator.generate(
        category=category, count=count, provider=provider, api_key=api_key
    )
    await _send(ws, IpcMessage.progress(msg.id, "Processing response", 80))
    await _send(ws, IpcMessage.progress(msg.id, "Complete", 100))
    await _send(ws, IpcMessage.result(msg.id, {"facts": facts}))


# ---------------------------------------------------------------------------
# Video Download (yt-dlp)
# ---------------------------------------------------------------------------

async def _handle_download_video(ws: WebSocket, msg: IpcMessage) -> None:
    url = msg.payload.get("url", "")
    output_dir = msg.payload.get("output_dir")

    if not url:
        await _send(ws, IpcMessage.error(msg.id, "No URL provided."))
        return

    async def on_progress(pct: int, stage: str) -> None:
        await _send(ws, IpcMessage.progress(msg.id, stage, pct))

    result = await download_video(url, output_dir=output_dir, on_progress=on_progress)
    await _send(ws, IpcMessage.progress(msg.id, "Complete", 100))
    await _send(ws, IpcMessage.result(msg.id, result))


# ---------------------------------------------------------------------------
# Proxy Generation (FFmpeg 720p)
# ---------------------------------------------------------------------------

async def _handle_generate_proxy(ws: WebSocket, msg: IpcMessage) -> None:
    source_path = msg.payload.get("source_path", "")

    if not source_path:
        await _send(ws, IpcMessage.error(msg.id, "No source_path provided."))
        return

    async def on_progress(pct: int, stage: str) -> None:
        await _send(ws, IpcMessage.progress(msg.id, stage, pct))

    result = await generate_proxy(source_path, on_progress=on_progress)
    await _send(ws, IpcMessage.result(msg.id, result))


# ---------------------------------------------------------------------------
# Transcription (OpenAI Whisper API)
# ---------------------------------------------------------------------------

async def _handle_transcribe(ws: WebSocket, msg: IpcMessage) -> None:
    audio_path = msg.payload.get("audio_path", "")
    api_key = msg.payload.get("api_key", "")

    if not audio_path:
        await _send(ws, IpcMessage.error(msg.id, "No audio_path provided."))
        return
    if not api_key:
        await _send(
            ws,
            IpcMessage.error(
                msg.id,
                "No OpenAI API key provided. Transcription requires an OpenAI key. "
                "Add one in Settings.",
            ),
        )
        return

    async def on_progress(pct: int, stage: str) -> None:
        await _send(ws, IpcMessage.progress(msg.id, stage, pct))

    result = await transcribe_audio(audio_path, api_key, on_progress=on_progress)
    await _send(ws, IpcMessage.result(msg.id, result))


# ---------------------------------------------------------------------------
# FFmpeg Render (Final Export)
# ---------------------------------------------------------------------------

async def _handle_ffmpeg_render(ws: WebSocket, msg: IpcMessage) -> None:
    inputs = msg.payload.get("inputs", [])
    output_path = msg.payload.get("output_path", "")
    resolution = msg.payload.get("resolution", "1080x1920")

    if not inputs or not output_path:
        await _send(ws, IpcMessage.error(msg.id, "Missing inputs or output_path."))
        return

    async def on_progress(pct: int, stage: str) -> None:
        await _send(ws, IpcMessage.progress(msg.id, stage, pct))

    result = await ffmpeg_render(
        inputs, output_path, resolution=resolution, on_progress=on_progress,
    )
    await _send(ws, IpcMessage.result(msg.id, result))


# ---------------------------------------------------------------------------
# Text-to-Speech (OpenAI TTS API)
# ---------------------------------------------------------------------------

async def _handle_generate_tts(ws: WebSocket, msg: IpcMessage) -> None:
    text = msg.payload.get("text", "")
    api_key = msg.payload.get("api_key", "")
    voice = msg.payload.get("voice", "alloy")

    if not text:
        await _send(ws, IpcMessage.error(msg.id, "No text provided."))
        return
    if not api_key:
        await _send(
            ws,
            IpcMessage.error(
                msg.id,
                "No OpenAI API key provided. TTS requires an OpenAI key. "
                "Add one in Settings.",
            ),
        )
        return

    async def on_progress(pct: int, stage: str) -> None:
        await _send(ws, IpcMessage.progress(msg.id, stage, pct))

    result = await generate_tts(
        text, api_key, voice=voice, on_progress=on_progress,
    )
    await _send(ws, IpcMessage.result(msg.id, result))


# ---------------------------------------------------------------------------
# Stock Footage (Pexels / Pixabay)
# ---------------------------------------------------------------------------

async def _handle_query_stock_footage(
    ws: WebSocket, msg: IpcMessage, stock_footage: StockFootageService
) -> None:
    keyword = msg.payload.get("keyword", "")
    pexels_key = msg.payload.get("pexels_key")
    pixabay_key = msg.payload.get("pixabay_key")

    if not keyword:
        await _send(ws, IpcMessage.error(msg.id, "No keyword provided."))
        return
    if not pexels_key and not pixabay_key:
        await _send(
            ws,
            IpcMessage.error(
                msg.id,
                "No Pexels or Pixabay API key provided. "
                "Add at least one stock footage API key in Settings.",
            ),
        )
        return

    await _send(ws, IpcMessage.progress(msg.id, "Searching stock footage", 20))
    results = await stock_footage.search(
        keyword, pexels_key=pexels_key, pixabay_key=pixabay_key,
    )
    await _send(ws, IpcMessage.progress(msg.id, "Complete", 100))
    await _send(ws, IpcMessage.result(msg.id, {"clips": results}))
