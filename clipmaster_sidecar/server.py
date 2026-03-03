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
    download_clip,
    download_video,
    ffmpeg_render,
    generate_proxy,
    generate_tts,
    transcribe_audio,
)
from .services.script_analyzer import ScriptAnalyzer
from .services.stock_footage import StockFootageService
from .services.twitch_search import TwitchSearchService
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
    twitch_search = TwitchSearchService()

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
                        stock_footage, youtube_search, twitch_search,
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
    twitch_search: TwitchSearchService,
) -> None:
    """Route an incoming IPC message to the correct service handler."""
    try:
        match msg.type:
            case MessageType.ping:
                await _send(ws, IpcMessage(id=msg.id, type=MessageType.pong, payload={}))

            case MessageType.analyze_script:
                await _handle_analyze_script(ws, msg, script_analyzer)

            case MessageType.scout_trending:
                await _handle_scout_trending(ws, msg, viral_scout, youtube_search, twitch_search)

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

            case MessageType.create_short:
                await _handle_create_short(ws, msg, stock_footage)

            case MessageType.scout_channel:
                await _handle_scout_channel(ws, msg, youtube_search, twitch_search)

            case MessageType.scout_vods:
                await _handle_scout_vods(ws, msg, youtube_search, twitch_search)

            case MessageType.scout_clips:
                await _handle_scout_clips(ws, msg, twitch_search)

            case MessageType.download_clip:
                await _handle_download_clip(ws, msg)

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
    twitch_search: TwitchSearchService,
) -> None:
    platform = msg.payload.get("platform", "youtube")
    limit = msg.payload.get("limit", 20)
    api_key = msg.payload.get("api_key", "")
    query = msg.payload.get("query", "")
    twitch_client_id = msg.payload.get("twitch_client_id", "")
    twitch_client_secret = msg.payload.get("twitch_client_secret", "")

    # ── Twitch via Helix API ──
    if platform == "twitch":
        if not twitch_client_id or not twitch_client_secret:
            await _send(
                ws,
                IpcMessage.error(
                    msg.id,
                    "Twitch Client ID and Secret are required for Twitch Scout. "
                    "Add TWITCH_CLIENT_ID and TWITCH_CLIENT_SECRET to your .env file.",
                ),
            )
            return

        await _send(ws, IpcMessage.progress(msg.id, "Querying Twitch API", 10))
        try:
            if query:
                results = await twitch_search.search_clips(
                    client_id=twitch_client_id,
                    client_secret=twitch_client_secret,
                    query=query,
                    limit=limit,
                )
            else:
                results = await twitch_search.search_trending(
                    client_id=twitch_client_id,
                    client_secret=twitch_client_secret,
                    limit=limit,
                )
            await _send(ws, IpcMessage.progress(msg.id, "Ranking results", 80))
            await _send(ws, IpcMessage.progress(msg.id, "Complete", 100))
            await _send(ws, IpcMessage.result(msg.id, {"videos": results}))
        except ValueError as exc:
            await _send(ws, IpcMessage.error(msg.id, str(exc)))
        return

    # ── YouTube via Data API ──
    if platform == "youtube" and api_key:
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

    # ── Fallback: yt-dlp scraping (YouTube only, no API key) ──
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


# ---------------------------------------------------------------------------
# Create Short (Full Pipeline: TTS + Text Video + Merge)
# ---------------------------------------------------------------------------

async def _handle_create_short(
    ws: WebSocket,
    msg: IpcMessage,
    stock_footage: StockFootageService,
) -> None:
    text = msg.payload.get("text", "")
    title = msg.payload.get("title", "Untitled Fact")
    api_key = msg.payload.get("api_key", "")
    voice = msg.payload.get("voice", "onyx")
    output_dir = msg.payload.get("output_dir", "")
    visual_keywords = msg.payload.get("visual_keywords", [])
    pexels_key = msg.payload.get("pexels_key")
    pixabay_key = msg.payload.get("pixabay_key")

    if not text:
        await _send(ws, IpcMessage.error(msg.id, "No text provided."))
        return
    if not api_key:
        await _send(ws, IpcMessage.error(
            msg.id,
            "No OpenAI API key provided. Add one in Settings.",
        ))
        return

    ffmpeg = _find_ffmpeg()
    if not ffmpeg:
        await _send(ws, IpcMessage.error(
            msg.id,
            "FFmpeg not found. Install FFmpeg or place it in bundled_binaries/.",
        ))
        return

    import os
    import re
    import tempfile

    if not output_dir:
        output_dir = os.path.join(tempfile.gettempdir(), "clipmaster_shorts")
    os.makedirs(output_dir, exist_ok=True)

    # Step 1: Generate TTS voiceover
    await _send(ws, IpcMessage.progress(msg.id, "Generating voiceover", 10))
    tts_result = await generate_tts(text, api_key, voice=voice)
    audio_path = tts_result["audio_path"]
    duration_est = tts_result["duration_estimate"]

    # Get actual audio duration via ffprobe
    duration = await _get_audio_duration(ffmpeg, audio_path)
    if duration <= 0:
        duration = max(duration_est, 5.0)

    # Step 2: Try to get a stock footage background
    await _send(ws, IpcMessage.progress(msg.id, "Searching for background footage", 30))
    bg_video_path = None
    if visual_keywords and (pexels_key or pixabay_key):
        for kw in visual_keywords[:3]:
            clips = await stock_footage.search(
                kw, pexels_key=pexels_key, pixabay_key=pixabay_key, per_source=1,
            )
            if clips:
                # Download the first clip
                clip_url = clips[0].get("download_url", "")
                if clip_url:
                    try:
                        import httpx
                        async with httpx.AsyncClient(timeout=30.0) as client:
                            resp = await client.get(clip_url)
                            resp.raise_for_status()
                            bg_path = os.path.join(
                                tempfile.gettempdir(),
                                f"clipmaster_bg_{kw.replace(' ', '_')}.mp4",
                            )
                            with open(bg_path, "wb") as f:
                                f.write(resp.content)
                            bg_video_path = bg_path
                            break
                    except Exception as exc:
                        logger.warning("Failed to download stock clip: %s", exc)

    # Step 3: Build the video
    await _send(ws, IpcMessage.progress(msg.id, "Rendering video", 50))

    safe_name = re.sub(r"[^\w\s-]", "", title[:40]).strip().replace(" ", "_")
    output_path = os.path.join(output_dir, f"short_{safe_name}.mp4")

    # Escape text for FFmpeg drawtext filter
    escaped_text = _escape_ffmpeg_text(text)
    escaped_title = _escape_ffmpeg_text(title)

    if bg_video_path and os.path.isfile(bg_video_path):
        # Use stock footage as background, scaled to 9:16, with text overlay
        cmd = [
            ffmpeg, "-y",
            "-stream_loop", "-1", "-i", bg_video_path,
            "-i", audio_path,
            "-vf", (
                f"scale=1080:1920:force_original_aspect_ratio=increase,"
                f"crop=1080:1920,"
                f"drawtext=text='{escaped_title}':fontsize=56:fontcolor=white:"
                f"x=(w-text_w)/2:y=200:borderw=3:bordercolor=black,"
                f"drawtext=text='{escaped_text}':fontsize=36:fontcolor=white:"
                f"x=(w-text_w)/2:y=(h-text_h)/2:borderw=2:bordercolor=black"
            ),
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
            "-c:a", "aac", "-b:a", "192k",
            "-t", str(duration),
            "-shortest",
            "-pix_fmt", "yuv420p",
            output_path,
        ]
    else:
        # Solid gradient background with text overlay
        cmd = [
            ffmpeg, "-y",
            "-f", "lavfi",
            "-i", (
                f"color=c=0x1a1a2e:s=1080x1920:d={duration},"
                f"drawtext=text='{escaped_title}':fontsize=56:fontcolor=white:"
                f"x=(w-text_w)/2:y=300:borderw=3:bordercolor=0x6C5CE7,"
                f"drawtext=text='{escaped_text}':fontsize=36:fontcolor=white:"
                f"x=(w-text_w)/2:y=(h-text_h)/2:borderw=2:bordercolor=black"
            ),
            "-i", audio_path,
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
            "-c:a", "aac", "-b:a", "192k",
            "-t", str(duration),
            "-shortest",
            "-pix_fmt", "yuv420p",
            output_path,
        ]

    await _send(ws, IpcMessage.progress(msg.id, "Encoding video", 65))

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    _, stderr_data = await proc.communicate()

    if proc.returncode != 0:
        err = stderr_data.decode("utf-8", errors="replace")[:500]
        logger.error("FFmpeg create_short failed: %s", err)
        await _send(ws, IpcMessage.error(msg.id, f"Video render failed: {err}"))
        return

    await _send(ws, IpcMessage.progress(msg.id, "Complete", 100))
    await _send(ws, IpcMessage.result(msg.id, {
        "output_path": output_path,
        "audio_path": audio_path,
        "duration": duration,
        "has_stock_footage": bg_video_path is not None,
    }))


def _find_ffmpeg() -> str | None:
    """Find FFmpeg binary."""
    import os
    import shutil
    on_path = shutil.which("ffmpeg")
    if on_path:
        return on_path
    sidecar_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    install_dir = os.path.dirname(sidecar_dir)
    exe = "ffmpeg.exe" if os.name == "nt" else "ffmpeg"
    bundled = os.path.join(install_dir, "bundled_binaries", exe)
    if os.path.isfile(bundled):
        return bundled
    return None


def _escape_ffmpeg_text(text: str) -> str:
    """Escape text for FFmpeg drawtext filter."""
    # FFmpeg drawtext requires escaping: ' : \ and newlines
    text = text.replace("\\", "\\\\\\\\")
    text = text.replace("'", "\u2019")  # Replace with typographic apostrophe
    text = text.replace(":", "\\:")
    text = text.replace("%", "%%")
    # Wrap long text manually (approx 35 chars per line for 1080px @ fontsize 36)
    words = text.split()
    lines = []
    current_line = ""
    for word in words:
        if len(current_line) + len(word) + 1 > 35:
            lines.append(current_line)
            current_line = word
        else:
            current_line = f"{current_line} {word}".strip()
    if current_line:
        lines.append(current_line)
    return "\\n".join(lines)


async def _get_audio_duration(ffmpeg: str, audio_path: str) -> float:
    """Get audio duration using ffprobe."""
    import os
    import json
    ffprobe = ffmpeg.replace("ffmpeg", "ffprobe")
    if not os.path.isfile(ffprobe) and not os.path.isfile(ffprobe + ".exe"):
        import shutil
        ffprobe = shutil.which("ffprobe") or ffprobe
    try:
        proc = await asyncio.create_subprocess_exec(
            ffprobe,
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "json",
            audio_path,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await proc.communicate()
        data = json.loads(stdout.decode())
        return float(data.get("format", {}).get("duration", 0))
    except Exception:
        return 0.0


# ---------------------------------------------------------------------------
# Channel-First Discovery
# ---------------------------------------------------------------------------

async def _handle_scout_channel(
    ws: WebSocket,
    msg: IpcMessage,
    youtube_search: YouTubeSearchService,
    twitch_search: TwitchSearchService,
) -> None:
    """Search for a channel/user by name on YouTube or Twitch."""
    platform = msg.payload.get("platform", "youtube")
    query = msg.payload.get("query", "")
    api_key = msg.payload.get("api_key", "")
    twitch_client_id = msg.payload.get("twitch_client_id", "")
    twitch_client_secret = msg.payload.get("twitch_client_secret", "")

    if not query:
        await _send(ws, IpcMessage.error(msg.id, "No channel name provided."))
        return

    await _send(ws, IpcMessage.progress(msg.id, "Searching channel", 20))

    try:
        if platform == "twitch":
            if not twitch_client_id or not twitch_client_secret:
                await _send(ws, IpcMessage.error(
                    msg.id, "Twitch Client ID and Secret required."))
                return
            result = await twitch_search.search_channel(
                twitch_client_id, twitch_client_secret, query)
        else:
            if not api_key:
                await _send(ws, IpcMessage.error(
                    msg.id, "YouTube API key required."))
                return
            result = await youtube_search.search_channel(api_key, query)

        if result is None:
            await _send(ws, IpcMessage.error(
                msg.id, f"No {platform} channel found for '{query}'."))
            return

        await _send(ws, IpcMessage.progress(msg.id, "Complete", 100))
        await _send(ws, IpcMessage.result(msg.id, {"channel": result}))

    except ValueError as exc:
        await _send(ws, IpcMessage.error(msg.id, str(exc)))


async def _handle_scout_vods(
    ws: WebSocket,
    msg: IpcMessage,
    youtube_search: YouTubeSearchService,
    twitch_search: TwitchSearchService,
) -> None:
    """Fetch VODs/videos for a given channel."""
    platform = msg.payload.get("platform", "youtube")
    limit = msg.payload.get("limit", 20)
    api_key = msg.payload.get("api_key", "")
    twitch_client_id = msg.payload.get("twitch_client_id", "")
    twitch_client_secret = msg.payload.get("twitch_client_secret", "")

    await _send(ws, IpcMessage.progress(msg.id, "Fetching videos", 20))

    try:
        if platform == "twitch":
            user_id = msg.payload.get("user_id", "")
            if not user_id:
                await _send(ws, IpcMessage.error(msg.id, "No user_id provided."))
                return
            vods = await twitch_search.get_vods(
                twitch_client_id, twitch_client_secret, user_id, limit=limit)
            await _send(ws, IpcMessage.progress(msg.id, "Complete", 100))
            await _send(ws, IpcMessage.result(msg.id, {"vods": vods}))
        else:
            channel_id = msg.payload.get("channel_id", "")
            if not channel_id:
                await _send(ws, IpcMessage.error(msg.id, "No channel_id provided."))
                return
            videos = await youtube_search.get_channel_videos(
                api_key, channel_id, limit=limit)
            await _send(ws, IpcMessage.progress(msg.id, "Complete", 100))
            await _send(ws, IpcMessage.result(msg.id, {"vods": videos}))

    except ValueError as exc:
        await _send(ws, IpcMessage.error(msg.id, str(exc)))


async def _handle_scout_clips(
    ws: WebSocket,
    msg: IpcMessage,
    twitch_search: TwitchSearchService,
) -> None:
    """Fetch viewer-created clips for a Twitch broadcaster/VOD."""
    broadcaster_id = msg.payload.get("broadcaster_id", "")
    vod_id = msg.payload.get("vod_id")
    limit = msg.payload.get("limit", 20)
    twitch_client_id = msg.payload.get("twitch_client_id", "")
    twitch_client_secret = msg.payload.get("twitch_client_secret", "")

    if not broadcaster_id:
        await _send(ws, IpcMessage.error(msg.id, "No broadcaster_id provided."))
        return

    await _send(ws, IpcMessage.progress(msg.id, "Fetching clips", 20))

    try:
        clips = await twitch_search.get_clips_for_broadcaster(
            twitch_client_id, twitch_client_secret,
            broadcaster_id, vod_id=vod_id, limit=limit,
        )
        await _send(ws, IpcMessage.progress(msg.id, "Complete", 100))
        await _send(ws, IpcMessage.result(msg.id, {"clips": clips}))

    except ValueError as exc:
        await _send(ws, IpcMessage.error(msg.id, str(exc)))


async def _handle_download_clip(ws: WebSocket, msg: IpcMessage) -> None:
    """Download a partial clip from a video using stream seeking."""
    url = msg.payload.get("url", "")
    start_time = msg.payload.get("start_time", "")
    end_time = msg.payload.get("end_time", "")
    output_name = msg.payload.get("output_name")

    if not url:
        await _send(ws, IpcMessage.error(msg.id, "No URL provided."))
        return
    if not start_time or not end_time:
        await _send(ws, IpcMessage.error(msg.id, "start_time and end_time required."))
        return

    try:
        result = await download_clip(
            url, start_time, end_time,
            output_name=output_name,
            on_progress=lambda pct, stage: _send(
                ws, IpcMessage.progress(msg.id, stage, pct)),
        )
        await _send(ws, IpcMessage.progress(msg.id, "Complete", 100))
        await _send(ws, IpcMessage.result(msg.id, result))
    except Exception as exc:
        logger.error("Clip download failed: %s", exc)
        await _send(ws, IpcMessage.error(msg.id, f"Clip download failed: {exc}"))
