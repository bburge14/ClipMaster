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

            case MessageType.preview_snapshot:
                await _handle_preview_snapshot(ws, msg)

            case MessageType.preview_video_clip:
                await _handle_preview_video_clip(ws, msg)

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

    # Style params — font sizes come directly from the UI in 1080p pixels
    # (no re-computation needed, exact WYSIWYG)
    title_font_size = int(msg.payload.get("title_font_size_px", 48))
    body_font_size = int(msg.payload.get("body_font_size_px", 40))
    # Legacy fallback: if old-style font_size is sent, compute from it
    if "font_size" in msg.payload and "title_font_size_px" not in msg.payload:
        font_size = int(msg.payload["font_size"])
        title_font_size = int(min(max(font_size * 0.45, 12), 24) * 4)
        body_font_size = int(min(max(font_size * 0.3, 8), 16) * 4)

    title_pos_x = float(msg.payload.get("title_pos_x", 0.5))
    title_pos_y = float(msg.payload.get("title_pos_y", 0.08))
    text_pos_y = float(msg.payload.get("text_pos_y", 0.75))
    text_pos_x = float(msg.payload.get("text_pos_x", 0.5))
    text_box_w = float(msg.payload.get("text_box_w", 0.85))

    # Separate title/body styling
    title_color = msg.payload.get("title_color", "white")
    title_font_family = msg.payload.get("title_font_family", "")
    title_shadow = bool(msg.payload.get("title_shadow", True))
    body_color = msg.payload.get("body_color", "white")
    body_font_family = msg.payload.get("body_font_family", "")
    body_shadow = bool(msg.payload.get("body_shadow", True))

    # Slideshow mode
    slideshow_enabled = bool(msg.payload.get("slideshow_enabled", False))
    words_per_slide = int(msg.payload.get("words_per_slide", 15))

    # Text box background (new)
    title_bg_enabled = bool(msg.payload.get("title_bg_enabled", False))
    title_bg_color = msg.payload.get("title_bg_color", "black@0.5")
    body_bg_enabled = bool(msg.payload.get("body_bg_enabled", False))
    body_bg_color = msg.payload.get("body_bg_color", "black@0.5")

    # Category badge (new)
    category_label = msg.payload.get("category_label", "")

    # Background music/sound clip (new)
    bg_music_path = msg.payload.get("bg_music_path", "")
    bg_music_volume = float(msg.payload.get("bg_music_volume", 0.15))

    # Multiple background URLs (cycle) or single fallback
    background_video_urls = msg.payload.get("background_video_urls", [])
    background_video_url = msg.payload.get("background_video_url", "")

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

    # Step 2: Get background video(s) — download user-selected clips or search
    await _send(ws, IpcMessage.progress(msg.id, "Getting background footage", 30))
    bg_video_paths: list[str] = []

    # Collect all background URLs
    bg_urls = [u for u in background_video_urls if u]
    if not bg_urls and background_video_url:
        bg_urls = [background_video_url]
    if not bg_urls and visual_keywords and (pexels_key or pixabay_key):
        for kw in visual_keywords[:3]:
            clips = await stock_footage.search(
                kw, pexels_key=pexels_key, pixabay_key=pixabay_key, per_source=1,
            )
            if clips:
                url = clips[0].get("download_url", "")
                if url:
                    bg_urls.append(url)
                    break

    # Download each background clip
    if bg_urls:
        import httpx
        async with httpx.AsyncClient(
            timeout=60.0, follow_redirects=True,
        ) as client:
            for i, bg_url in enumerate(bg_urls):
                try:
                    resp = await client.get(bg_url)
                    resp.raise_for_status()
                    bg_path = os.path.join(
                        tempfile.gettempdir(),
                        f"clipmaster_bg_{i}.mp4",
                    )
                    with open(bg_path, "wb") as f:
                        f.write(resp.content)
                    bg_video_paths.append(bg_path)
                    logger.info("Downloaded bg %d: %d bytes", i, len(resp.content))
                except Exception as exc:
                    logger.warning("Failed to download bg %d from %s: %s", i, bg_url, exc)

    # Step 3: If multiple backgrounds, concat them into a single looping bg
    await _send(ws, IpcMessage.progress(msg.id, "Rendering video", 50))
    bg_video_path = None
    if len(bg_video_paths) > 1:
        # Create concat file and merge clips into one background
        concat_file = os.path.join(tempfile.gettempdir(), "clipmaster_concat.txt")
        concat_out = os.path.join(tempfile.gettempdir(), "clipmaster_bg_concat.mp4")
        # Each clip gets equal share of duration, loop through all
        with open(concat_file, "w") as cf:
            for bp in bg_video_paths:
                # Forward slashes avoid Windows backslash issues in concat files
                cf.write(f"file '{bp.replace(chr(92), '/')}'\n")
        await _send(ws, IpcMessage.progress(msg.id, "Combining backgrounds", 55))
        concat_cmd = [
            ffmpeg, "-y",
            "-f", "concat", "-safe", "0", "-i", concat_file,
            "-vf", "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
            "-t", str(duration),
            "-an",
            "-pix_fmt", "yuv420p",
            concat_out,
        ]
        proc = await asyncio.create_subprocess_exec(
            *concat_cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await proc.communicate()
        if proc.returncode == 0 and os.path.isfile(concat_out):
            bg_video_path = concat_out
            logger.info("Concatenated %d backgrounds", len(bg_video_paths))
        else:
            logger.warning("Concat failed, using first bg: %s",
                           stderr.decode("utf-8", errors="replace")[-200:])
            bg_video_path = bg_video_paths[0]
    elif len(bg_video_paths) == 1:
        bg_video_path = bg_video_paths[0]

    safe_name = re.sub(r"[^\w\s-]", "", title[:40]).strip().replace(" ", "_")
    output_path = os.path.join(output_dir, f"short_{safe_name}.mp4")
    # FFmpeg works best with forward slashes, even on Windows
    output_path = output_path.replace("\\", "/")

    # ── Write text + font to temp dir with bare filenames ──
    # We run FFmpeg with cwd=tmpdir so drawtext can use bare filenames,
    # completely avoiding Windows C: colon issues in filter strings.
    tmpdir = tempfile.gettempdir()
    title_file = os.path.join(tmpdir, "cm_title.txt")
    body_file = os.path.join(tmpdir, "cm_body.txt")

    # Word-wrap title: preview shows left:16, right:16 on 270px → (270-32)/270 ≈ 88%
    # On 1080px canvas that's ~952px usable. Wrap to max 2 lines.
    title_usable_px = int(0.88 * 1080)
    title_avg_char_w = max(title_font_size * 0.55, 1)
    title_chars = max(10, int(title_usable_px / title_avg_char_w))
    wrapped_title = _wrap_text(title, title_chars)
    # Cap at 2 lines like the preview
    title_lines = wrapped_title.split("\n")[:2]
    wrapped_title = "\n".join(title_lines)

    # Word-wrap body text to match the visible text box.
    # Use same 0.52 factor as Dart _wrapText() for consistency.
    body_box_w_px = int(text_box_w * 1080)
    # Subtract padding: preview has padding=6 on 270px → ×4 = 24px each side
    body_usable_px = body_box_w_px - 48
    avg_char_w = max(body_font_size * 0.52, 1)
    chars_per_line = max(15, int(body_usable_px / avg_char_w))

    # Slideshow mode: split text into separate slide files
    slide_files: list[str] = []
    if slideshow_enabled:
        words = text.split()
        for si in range(0, len(words), words_per_slide):
            slide_text = " ".join(words[si:si + words_per_slide])
            wrapped = _wrap_text(slide_text, chars_per_line)
            clean = wrapped.encode("ascii", errors="ignore").decode("ascii").strip()
            if not clean:
                clean = wrapped.strip()
            slide_path = os.path.join(tmpdir, f"cm_slide_{len(slide_files)}.txt")
            with open(slide_path, "w", encoding="utf-8", newline="\n") as f:
                f.write(clean)
            slide_files.append(f"cm_slide_{len(slide_files)}.txt")
    else:
        wrapped_body = _wrap_text(text, chars_per_line)

    # Strip any BOM / invisible unicode chars that cause box glyphs in FFmpeg
    clean_title = wrapped_title.encode("ascii", errors="ignore").decode("ascii").strip()
    if not clean_title:
        clean_title = title.strip()
    with open(title_file, "w", encoding="utf-8", newline="\n") as f:
        f.write(clean_title)

    if not slideshow_enabled:
        clean_body = wrapped_body.encode("ascii", errors="ignore").decode("ascii").strip()
        if not clean_body:
            clean_body = wrapped_body.strip()
        with open(body_file, "w", encoding="utf-8", newline="\n") as f:
            f.write(clean_body)

    # Copy font(s) to temp dir so we can reference by bare filename
    import shutil
    font_family = msg.payload.get("font_family", "")

    # Title font
    title_font_name = title_font_family if title_font_family else font_family
    title_font_file = _find_font(preferred_name=title_font_name if title_font_name else None)
    title_font_opt = ""
    if title_font_file:
        font_tmp = os.path.join(tmpdir, "cm_font_title.ttf")
        try:
            shutil.copy2(title_font_file, font_tmp)
            title_font_opt = ":fontfile=cm_font_title.ttf"
        except Exception:
            logger.warning("Could not copy title font %s to temp dir", title_font_file)

    # Body font
    body_font_name = body_font_family if body_font_family else font_family
    body_font_file = _find_font(preferred_name=body_font_name if body_font_name else None)
    body_font_opt = ""
    if body_font_file:
        font_tmp = os.path.join(tmpdir, "cm_font_body.ttf")
        try:
            shutil.copy2(body_font_file, font_tmp)
            body_font_opt = ":fontfile=cm_font_body.ttf"
        except Exception:
            logger.warning("Could not copy body font %s to temp dir", body_font_file)

    # Build drawtext filters — match Flutter preview pixel-for-pixel
    border_opts = ":borderw=3:bordercolor=black" if title_shadow else ""
    body_border = ":borderw=2:bordercolor=black" if body_shadow else ""

    effective_title_color = title_color
    effective_body_color = body_color

    # Title position: preview uses top: frameH * title_pos_y
    title_y = int(title_pos_y * 1920)
    # Title X: preview offsets from center via title_pos_x (0.5 = centered)
    # In FFmpeg: x = title_pos_x * 1080 - text_w/2
    title_x_expr = f"({int(title_pos_x * 1080)}-text_w/2)"

    # Body text: preview puts box CENTER at (text_pos_x, text_pos_y),
    # box top = center_y - boxH/2, then text starts at box top + padding(24px)
    text_box_h = float(msg.payload.get("text_box_h", 0.35))
    body_box_top = int(text_pos_y * 1920 - (text_box_h * 1920) / 2)
    body_y = max(0, body_box_top + 24)  # +24px for padding (6px × 4 scale)

    # Body box X: preview centers box at text_pos_x
    body_box_left = int(text_pos_x * 1080 - body_box_w_px / 2)
    # Body X expression: center text at text_pos_x (respect drag position)
    body_x_expr = f"({int(text_pos_x * 1080)}-text_w/2)"

    # Bare filenames — FFmpeg cwd will be set to tmpdir
    drawtext_title = (
        f"drawtext=textfile=cm_title.txt"
        f":fontsize={title_font_size}:fontcolor={effective_title_color}"
        f":x={title_x_expr}:y={title_y}"
        f"{title_font_opt}{border_opts}"
    )

    # Body text: single drawtext or multiple for slideshow
    drawtext_body_parts: list[str] = []
    if slideshow_enabled and slide_files:
        # Each slide shown for equal duration
        slide_dur = duration / len(slide_files) if duration > 0 else 5.0
        for si, slide_fname in enumerate(slide_files):
            t_start = si * slide_dur
            t_end = (si + 1) * slide_dur
            drawtext_body_parts.append(
                f"drawtext=textfile={slide_fname}"
                f":fontsize={body_font_size}:fontcolor={effective_body_color}"
                f":x={body_x_expr}:y={body_y}"
                f"{body_font_opt}{body_border}"
                f":enable='between(t,{t_start:.2f},{t_end:.2f})'"
            )
    else:
        drawtext_body_parts.append(
            f"drawtext=textfile=cm_body.txt"
            f":fontsize={body_font_size}:fontcolor={effective_body_color}"
            f":x={body_x_expr}:y={body_y}"
            f"{body_font_opt}{body_border}"
        )

    # Title text box background (drawbox behind title)
    drawbox_title_bg = ""
    if title_bg_enabled:
        # Title box centered at title_pos_x with padding
        title_box_w = 952
        title_box_x = int(title_pos_x * 1080 - title_box_w / 2)
        title_box_x = max(0, title_box_x)
        drawbox_title_bg = (
            f"drawbox=x={title_box_x}:y={max(0, title_y - 16)}"
            f":w={title_box_w}:h={title_font_size * len(title_lines) + 32}"
            f":color={title_bg_color}:t=fill,"
        )

    # Body text box background (drawbox behind body)
    drawbox_body_bg = ""
    if body_bg_enabled:
        body_box_h_px = int(text_box_h * 1920)
        drawbox_body_bg = (
            f"drawbox=x={max(0, body_box_left)}"
            f":y={max(0, body_box_top)}"
            f":w={body_box_w_px}:h={body_box_h_px}"
            f":color={body_bg_color}:t=fill,"
        )

    # Category badge: small text at bottom center (matches preview)
    drawtext_category = ""
    if category_label:
        cat_file = os.path.join(tmpdir, "cm_category.txt")
        clean_cat = category_label.encode("ascii", errors="ignore").decode("ascii").strip()
        if not clean_cat:
            clean_cat = category_label.strip()
        with open(cat_file, "w", encoding="utf-8", newline="\n") as f:
            f.write(clean_cat)
        # Badge text at bottom, centered
        # Preview: bottom:12, padding h:10, v:3 on 270×480
        # → 1920 - 48(bottom margin) - 12(badge padding) - 40(font size) ≈ 1820
        badge_y = 1920 - 48 - 52
        badge_font_size = 40  # 10px preview × 4
        # Use drawtext with box=1 for built-in background box
        drawtext_category = (
            f",drawtext=textfile=cm_category.txt"
            f":fontsize={badge_font_size}:fontcolor=white"
            f":x=(w-text_w)/2:y={badge_y}"
            f":box=1:boxcolor=0x6C5CE7@0.6:boxborderw=12"
            f"{title_font_opt}"
        )

    # Ensure all -i / output paths are absolute (cwd will be tmpdir)
    audio_path = os.path.abspath(audio_path)
    output_path = os.path.abspath(output_path).replace("\\", "/")
    if bg_video_path:
        bg_video_path = os.path.abspath(bg_video_path)
    if bg_music_path:
        bg_music_path = os.path.abspath(bg_music_path)

    # Build the video filter chain — order matters for WYSIWYG fidelity:
    # 1. Scale/crop → 2. Dark overlay → 3. Text box backgrounds →
    # 4. Title text → 5. Body text(s) → 6. Category badge
    def _build_vf(include_scale: bool) -> str:
        parts = []
        if include_scale:
            parts.append(
                "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920"
            )
        parts.append("drawbox=x=0:y=0:w=iw:h=ih:color=black@0.3:t=fill")
        if drawbox_title_bg:
            parts.append(drawbox_title_bg.rstrip(","))
        if drawbox_body_bg:
            parts.append(drawbox_body_bg.rstrip(","))
        parts.append(drawtext_title)
        parts.extend(drawtext_body_parts)
        vf_str = ",".join(parts)
        if drawtext_category:
            vf_str += drawtext_category
        return vf_str

    # Determine audio inputs and mixing
    has_bg_music = bg_music_path and os.path.isfile(bg_music_path)

    if bg_video_path and os.path.isfile(bg_video_path):
        vf = _build_vf(include_scale=(len(bg_video_paths) <= 1))
        cmd = [
            ffmpeg, "-y",
            "-stream_loop", "-1", "-i", bg_video_path,
            "-i", audio_path,
        ]
        if has_bg_music:
            cmd.extend(["-i", bg_music_path])
            # Mix TTS voice (input 1) with background music (input 2)
            cmd.extend([
                "-filter_complex",
                f"[1:a]volume=1.0[voice];[2:a]volume={bg_music_volume}[music];"
                f"[voice][music]amix=inputs=2:duration=first[aout]",
                "-map", "0:v", "-map", "[aout]",
            ])
            cmd.extend(["-vf", vf])
        else:
            cmd.extend(["-vf", vf])
        cmd.extend([
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
            "-c:a", "aac", "-b:a", "192k",
            "-t", str(duration),
            "-shortest",
            "-pix_fmt", "yuv420p",
            output_path,
        ])
    else:
        # Solid dark background with text overlay
        vf = _build_vf(include_scale=False)
        cmd = [
            ffmpeg, "-y",
            "-f", "lavfi",
            "-i", f"color=c=0x1a1a2e:s=1080x1920:d={duration}",
            "-i", audio_path,
        ]
        if has_bg_music:
            cmd.extend(["-i", bg_music_path])
            cmd.extend([
                "-filter_complex",
                f"[1:a]volume=1.0[voice];[2:a]volume={bg_music_volume}[music];"
                f"[voice][music]amix=inputs=2:duration=first[aout]",
                "-map", "0:v", "-map", "[aout]",
            ])
            cmd.extend(["-vf", vf])
        else:
            cmd.extend(["-vf", vf])
        cmd.extend([
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
            "-c:a", "aac", "-b:a", "192k",
            "-t", str(duration),
            "-shortest",
            "-pix_fmt", "yuv420p",
            output_path,
        ])

    # Log filter string separately for debugging
    vf_idx = cmd.index("-vf") if "-vf" in cmd else -1
    if vf_idx >= 0 and vf_idx + 1 < len(cmd):
        logger.info("FFmpeg -vf filter: %s", cmd[vf_idx + 1])
    logger.info("FFmpeg command: %s", " ".join(cmd))
    await _send(ws, IpcMessage.progress(msg.id, "Encoding video", 65))

    # Run FFmpeg with cwd=tmpdir so bare filenames in drawtext resolve correctly
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        cwd=tmpdir,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    _, stderr_data = await proc.communicate()

    if proc.returncode != 0:
        err = stderr_data.decode("utf-8", errors="replace")[-500:]
        logger.error("FFmpeg create_short failed: %s", err)
        await _send(ws, IpcMessage.error(msg.id, f"Video render failed: {err}"))
        return

    await _send(ws, IpcMessage.progress(msg.id, "Complete", 100))
    await _send(ws, IpcMessage.result(msg.id, {
        "output_path": output_path,
        "audio_path": audio_path,
        "duration": duration,
        "has_stock_footage": bg_video_path is not None,
        "background_count": len(bg_video_paths),
    }))


async def _handle_preview_snapshot(
    ws: WebSocket,
    msg: IpcMessage,
) -> None:
    """Generate a single-frame PNG snapshot using the exact same FFmpeg filters
    as the final render, so the preview is true WYSIWYG."""
    import os
    import shutil
    import tempfile

    ffmpeg = _find_ffmpeg()
    if not ffmpeg:
        await _send(ws, IpcMessage.error(msg.id, "FFmpeg not found."))
        return

    p = msg.payload
    title = p.get("title", "Untitled Fact")
    text = p.get("text", "")
    title_font_size = int(p.get("title_font_size_px", 48))
    body_font_size = int(p.get("body_font_size_px", 40))
    title_pos_x = float(p.get("title_pos_x", 0.5))
    title_pos_y = float(p.get("title_pos_y", 0.08))
    text_pos_x = float(p.get("text_pos_x", 0.5))
    text_pos_y = float(p.get("text_pos_y", 0.75))
    text_box_w = float(p.get("text_box_w", 0.85))
    text_box_h = float(p.get("text_box_h", 0.35))
    title_color = p.get("title_color", "white")
    body_color = p.get("body_color", "white")
    title_font_family = p.get("title_font_family", "")
    body_font_family = p.get("body_font_family", "")
    title_shadow = bool(p.get("title_shadow", True))
    body_shadow = bool(p.get("body_shadow", True))
    title_bg_enabled = bool(p.get("title_bg_enabled", False))
    title_bg_color = p.get("title_bg_color", "black@0.5")
    body_bg_enabled = bool(p.get("body_bg_enabled", False))
    body_bg_color = p.get("body_bg_color", "black@0.5")
    category_label = p.get("category_label", "")
    slideshow_enabled = bool(p.get("slideshow_enabled", False))
    words_per_slide = int(p.get("words_per_slide", 15))

    # Background: either a local cached video frame or a gradient
    bg_video_path = p.get("bg_video_local_path", "")

    tmpdir = tempfile.gettempdir()
    snapshot_path = os.path.join(tmpdir, "cm_preview_snapshot.png")

    # ── Write text files (same logic as _handle_create_short) ──
    title_usable_px = int(0.88 * 1080)
    title_avg_char_w = max(title_font_size * 0.55, 1)
    title_chars = max(10, int(title_usable_px / title_avg_char_w))
    wrapped_title = _wrap_text(title, title_chars)
    title_lines = wrapped_title.split("\n")[:2]
    wrapped_title = "\n".join(title_lines)

    body_box_w_px = int(text_box_w * 1080)
    body_usable_px = body_box_w_px - 48
    avg_char_w = max(body_font_size * 0.52, 1)
    chars_per_line = max(15, int(body_usable_px / avg_char_w))

    # Write title
    clean_title = wrapped_title.encode("ascii", errors="ignore").decode("ascii").strip()
    if not clean_title:
        clean_title = title.strip()
    title_file = os.path.join(tmpdir, "cm_title.txt")
    with open(title_file, "w", encoding="utf-8", newline="\n") as f:
        f.write(clean_title)

    # Write body (show first slide if slideshow)
    if slideshow_enabled:
        words = text.split()
        first_slide = " ".join(words[:words_per_slide])
        wrapped_body = _wrap_text(first_slide, chars_per_line)
    else:
        wrapped_body = _wrap_text(text, chars_per_line)
    clean_body = wrapped_body.encode("ascii", errors="ignore").decode("ascii").strip()
    if not clean_body:
        clean_body = text.strip()
    body_file = os.path.join(tmpdir, "cm_body.txt")
    with open(body_file, "w", encoding="utf-8", newline="\n") as f:
        f.write(clean_body)

    # ── Fonts ──
    font_family = p.get("font_family", "")
    title_font_name = title_font_family or font_family
    title_font_file = _find_font(preferred_name=title_font_name or None)
    title_font_opt = ""
    if title_font_file:
        dst = os.path.join(tmpdir, "cm_font_title.ttf")
        try:
            shutil.copy2(title_font_file, dst)
            title_font_opt = ":fontfile=cm_font_title.ttf"
        except Exception:
            pass

    body_font_name = body_font_family or font_family
    body_font_file = _find_font(preferred_name=body_font_name or None)
    body_font_opt = ""
    if body_font_file:
        dst = os.path.join(tmpdir, "cm_font_body.ttf")
        try:
            shutil.copy2(body_font_file, dst)
            body_font_opt = ":fontfile=cm_font_body.ttf"
        except Exception:
            pass

    # ── Build filter chain (same as render) ──
    border_opts = ":borderw=3:bordercolor=black" if title_shadow else ""
    body_border = ":borderw=2:bordercolor=black" if body_shadow else ""

    title_y = int(title_pos_y * 1920)
    title_x_expr = f"({int(title_pos_x * 1080)}-text_w/2)"

    body_box_top = int(text_pos_y * 1920 - (text_box_h * 1920) / 2)
    body_y = max(0, body_box_top + 24)
    body_box_left = int(text_pos_x * 1080 - body_box_w_px / 2)

    # Body X: use actual position instead of always centering
    body_x_expr = f"({int(text_pos_x * 1080)}-text_w/2)"

    drawtext_title = (
        f"drawtext=textfile=cm_title.txt"
        f":fontsize={title_font_size}:fontcolor={title_color}"
        f":x={title_x_expr}:y={title_y}"
        f"{title_font_opt}{border_opts}"
    )

    drawtext_body = (
        f"drawtext=textfile=cm_body.txt"
        f":fontsize={body_font_size}:fontcolor={body_color}"
        f":x={body_x_expr}:y={body_y}"
        f"{body_font_opt}{body_border}"
    )

    # Background boxes
    drawbox_title_bg = ""
    if title_bg_enabled:
        title_box_w = 952
        title_box_x = max(0, int(title_pos_x * 1080 - title_box_w / 2))
        drawbox_title_bg = (
            f"drawbox=x={title_box_x}:y={max(0, title_y - 16)}"
            f":w={title_box_w}:h={title_font_size * len(title_lines) + 32}"
            f":color={title_bg_color}:t=fill"
        )

    drawbox_body_bg = ""
    if body_bg_enabled:
        body_box_h_px = int(text_box_h * 1920)
        drawbox_body_bg = (
            f"drawbox=x={max(0, body_box_left)}"
            f":y={max(0, body_box_top)}"
            f":w={body_box_w_px}:h={body_box_h_px}"
            f":color={body_bg_color}:t=fill"
        )

    # Category badge
    drawtext_category = ""
    if category_label:
        cat_file = os.path.join(tmpdir, "cm_category.txt")
        clean_cat = category_label.encode("ascii", errors="ignore").decode("ascii").strip() or category_label.strip()
        with open(cat_file, "w", encoding="utf-8", newline="\n") as f:
            f.write(clean_cat)
        badge_y = 1920 - 48 - 52
        badge_font_size = 40
        drawtext_category = (
            f",drawtext=textfile=cm_category.txt"
            f":fontsize={badge_font_size}:fontcolor=white"
            f":x=(w-text_w)/2:y={badge_y}"
            f":box=1:boxcolor=0x6C5CE7@0.6:boxborderw=12"
            f"{title_font_opt}"
        )

    # Assemble VF
    vf_parts = []
    if bg_video_path and os.path.isfile(bg_video_path):
        vf_parts.append("scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920")
    vf_parts.append("drawbox=x=0:y=0:w=iw:h=ih:color=black@0.3:t=fill")
    if drawbox_title_bg:
        vf_parts.append(drawbox_title_bg)
    if drawbox_body_bg:
        vf_parts.append(drawbox_body_bg)
    vf_parts.append(drawtext_title)
    vf_parts.append(drawtext_body)
    vf_str = ",".join(vf_parts)
    if drawtext_category:
        vf_str += drawtext_category

    # Build FFmpeg command: single frame PNG
    if bg_video_path and os.path.isfile(bg_video_path):
        # Use the actual background video frame
        bg_abs = os.path.abspath(bg_video_path)
        cmd = [
            ffmpeg, "-y",
            "-ss", "1",  # grab frame at 1 second
            "-i", bg_abs,
            "-vf", vf_str,
            "-frames:v", "1",
            "-pix_fmt", "rgb24",
            os.path.abspath(snapshot_path),
        ]
    else:
        # No bg video — generate a dark gradient background
        cmd = [
            ffmpeg, "-y",
            "-f", "lavfi",
            "-i", "color=c=0x1A1A2E:s=1080x1920:d=1,format=rgb24",
            "-vf", vf_str,
            "-frames:v", "1",
            os.path.abspath(snapshot_path),
        ]

    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=tmpdir,
        )
        _, stderr_bytes = await proc.communicate()
        if proc.returncode != 0:
            err = stderr_bytes.decode("utf-8", errors="replace")[-500:]
            logger.error("Preview snapshot FFmpeg error: %s", err)
            await _send(ws, IpcMessage.error(msg.id, f"FFmpeg preview failed: {err}"))
            return
        await _send(ws, IpcMessage.result(msg.id, {
            "snapshot_path": os.path.abspath(snapshot_path),
        }))
    except Exception as exc:
        logger.exception("Preview snapshot error")
        await _send(ws, IpcMessage.error(msg.id, str(exc)))


async def _handle_preview_video_clip(
    ws: WebSocket,
    msg: IpcMessage,
) -> None:
    """Generate a short (5-sec) looping preview video clip using the exact same
    FFmpeg drawtext filters as the final render — true WYSIWYG video preview."""
    import os
    import shutil
    import tempfile

    ffmpeg = _find_ffmpeg()
    if not ffmpeg:
        await _send(ws, IpcMessage.error(msg.id, "FFmpeg not found."))
        return

    p = msg.payload
    title = p.get("title", "Untitled Fact")
    text = p.get("text", "")
    title_font_size = int(p.get("title_font_size_px", 48))
    body_font_size = int(p.get("body_font_size_px", 40))
    title_pos_x = float(p.get("title_pos_x", 0.5))
    title_pos_y = float(p.get("title_pos_y", 0.08))
    text_pos_x = float(p.get("text_pos_x", 0.5))
    text_pos_y = float(p.get("text_pos_y", 0.75))
    text_box_w = float(p.get("text_box_w", 0.85))
    text_box_h = float(p.get("text_box_h", 0.35))
    title_color = p.get("title_color", "white")
    body_color = p.get("body_color", "white")
    title_font_family = p.get("title_font_family", "")
    body_font_family = p.get("body_font_family", "")
    title_shadow = bool(p.get("title_shadow", True))
    body_shadow = bool(p.get("body_shadow", True))
    title_bg_enabled = bool(p.get("title_bg_enabled", False))
    title_bg_color = p.get("title_bg_color", "black@0.5")
    body_bg_enabled = bool(p.get("body_bg_enabled", False))
    body_bg_color = p.get("body_bg_color", "black@0.5")
    category_label = p.get("category_label", "")
    slideshow_enabled = bool(p.get("slideshow_enabled", False))
    words_per_slide = int(p.get("words_per_slide", 15))
    bg_video_path = p.get("bg_video_local_path", "")

    clip_duration = 5  # seconds

    tmpdir = tempfile.gettempdir()
    clip_path = os.path.join(tmpdir, "cm_preview_clip.mp4")

    # ── Write text files (same logic as snapshot/render) ──
    title_usable_px = int(0.88 * 1080)
    title_avg_char_w = max(title_font_size * 0.55, 1)
    title_chars = max(10, int(title_usable_px / title_avg_char_w))
    wrapped_title = _wrap_text(title, title_chars)
    title_lines = wrapped_title.split("\n")[:2]
    wrapped_title = "\n".join(title_lines)

    body_box_w_px = int(text_box_w * 1080)
    body_usable_px = body_box_w_px - 48
    avg_char_w = max(body_font_size * 0.52, 1)
    chars_per_line = max(15, int(body_usable_px / avg_char_w))

    clean_title = wrapped_title.encode("ascii", errors="ignore").decode("ascii").strip()
    if not clean_title:
        clean_title = title.strip()
    title_file = os.path.join(tmpdir, "cm_title.txt")
    with open(title_file, "w", encoding="utf-8", newline="\n") as f:
        f.write(clean_title)

    if slideshow_enabled:
        words = text.split()
        first_slide = " ".join(words[:words_per_slide])
        wrapped_body = _wrap_text(first_slide, chars_per_line)
    else:
        wrapped_body = _wrap_text(text, chars_per_line)
    clean_body = wrapped_body.encode("ascii", errors="ignore").decode("ascii").strip()
    if not clean_body:
        clean_body = text.strip()
    body_file = os.path.join(tmpdir, "cm_body.txt")
    with open(body_file, "w", encoding="utf-8", newline="\n") as f:
        f.write(clean_body)

    # ── Fonts ──
    font_family = p.get("font_family", "")
    title_font_name = title_font_family or font_family
    title_font_file = _find_font(preferred_name=title_font_name or None)
    title_font_opt = ""
    if title_font_file:
        dst = os.path.join(tmpdir, "cm_font_title.ttf")
        try:
            shutil.copy2(title_font_file, dst)
            title_font_opt = ":fontfile=cm_font_title.ttf"
        except Exception:
            pass

    body_font_name = body_font_family or font_family
    body_font_file = _find_font(preferred_name=body_font_name or None)
    body_font_opt = ""
    if body_font_file:
        dst = os.path.join(tmpdir, "cm_font_body.ttf")
        try:
            shutil.copy2(body_font_file, dst)
            body_font_opt = ":fontfile=cm_font_body.ttf"
        except Exception:
            pass

    # ── Build filter chain (identical to snapshot/render) ──
    border_opts = ":borderw=3:bordercolor=black" if title_shadow else ""
    body_border = ":borderw=2:bordercolor=black" if body_shadow else ""

    title_y = int(title_pos_y * 1920)
    title_x_expr = f"({int(title_pos_x * 1080)}-text_w/2)"

    body_box_top = int(text_pos_y * 1920 - (text_box_h * 1920) / 2)
    body_y = max(0, body_box_top + 24)
    body_box_left = int(text_pos_x * 1080 - body_box_w_px / 2)
    body_x_expr = f"({int(text_pos_x * 1080)}-text_w/2)"

    drawtext_title = (
        f"drawtext=textfile=cm_title.txt"
        f":fontsize={title_font_size}:fontcolor={title_color}"
        f":x={title_x_expr}:y={title_y}"
        f"{title_font_opt}{border_opts}"
    )

    drawtext_body = (
        f"drawtext=textfile=cm_body.txt"
        f":fontsize={body_font_size}:fontcolor={body_color}"
        f":x={body_x_expr}:y={body_y}"
        f"{body_font_opt}{body_border}"
    )

    drawbox_title_bg = ""
    if title_bg_enabled:
        title_box_w = 952
        title_box_x = max(0, int(title_pos_x * 1080 - title_box_w / 2))
        drawbox_title_bg = (
            f"drawbox=x={title_box_x}:y={max(0, title_y - 16)}"
            f":w={title_box_w}:h={title_font_size * len(title_lines) + 32}"
            f":color={title_bg_color}:t=fill"
        )

    drawbox_body_bg = ""
    if body_bg_enabled:
        body_box_h_px = int(text_box_h * 1920)
        drawbox_body_bg = (
            f"drawbox=x={max(0, body_box_left)}"
            f":y={max(0, body_box_top)}"
            f":w={body_box_w_px}:h={body_box_h_px}"
            f":color={body_bg_color}:t=fill"
        )

    drawtext_category = ""
    if category_label:
        cat_file = os.path.join(tmpdir, "cm_category.txt")
        clean_cat = category_label.encode("ascii", errors="ignore").decode("ascii").strip() or category_label.strip()
        with open(cat_file, "w", encoding="utf-8", newline="\n") as f:
            f.write(clean_cat)
        badge_y = 1920 - 48 - 52
        badge_font_size = 40
        drawtext_category = (
            f",drawtext=textfile=cm_category.txt"
            f":fontsize={badge_font_size}:fontcolor=white"
            f":x=(w-text_w)/2:y={badge_y}"
            f":box=1:boxcolor=0x6C5CE7@0.6:boxborderw=12"
            f"{title_font_opt}"
        )

    # Assemble VF
    vf_parts = []
    if bg_video_path and os.path.isfile(bg_video_path):
        vf_parts.append("scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920")
    vf_parts.append("drawbox=x=0:y=0:w=iw:h=ih:color=black@0.3:t=fill")
    if drawbox_title_bg:
        vf_parts.append(drawbox_title_bg)
    if drawbox_body_bg:
        vf_parts.append(drawbox_body_bg)
    vf_parts.append(drawtext_title)
    vf_parts.append(drawtext_body)
    vf_str = ",".join(vf_parts)
    if drawtext_category:
        vf_str += drawtext_category

    # Build FFmpeg command: 5-second video clip (ultrafast for speed)
    if bg_video_path and os.path.isfile(bg_video_path):
        bg_abs = os.path.abspath(bg_video_path)
        cmd = [
            ffmpeg, "-y",
            "-stream_loop", "-1",
            "-i", bg_abs,
            "-t", str(clip_duration),
            "-vf", vf_str,
            "-c:v", "libx264",
            "-preset", "ultrafast",
            "-crf", "28",
            "-an",
            "-pix_fmt", "yuv420p",
            os.path.abspath(clip_path),
        ]
    else:
        cmd = [
            ffmpeg, "-y",
            "-f", "lavfi",
            "-i", f"color=c=0x1A1A2E:s=1080x1920:d={clip_duration},format=yuv420p",
            "-t", str(clip_duration),
            "-vf", vf_str,
            "-c:v", "libx264",
            "-preset", "ultrafast",
            "-crf", "28",
            "-an",
            "-pix_fmt", "yuv420p",
            os.path.abspath(clip_path),
        ]

    try:
        await _send(ws, IpcMessage.progress(msg.id, "Rendering preview clip…", 30))
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=tmpdir,
        )
        _, stderr_bytes = await proc.communicate()
        if proc.returncode != 0:
            err = stderr_bytes.decode("utf-8", errors="replace")[-500:]
            logger.error("Preview clip FFmpeg error: %s", err)
            await _send(ws, IpcMessage.error(msg.id, f"FFmpeg preview clip failed: {err}"))
            return
        await _send(ws, IpcMessage.result(msg.id, {
            "clip_path": os.path.abspath(clip_path),
        }))
    except Exception as exc:
        logger.exception("Preview clip error")
        await _send(ws, IpcMessage.error(msg.id, str(exc)))


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


def _escape_ffmpeg_path(path: str) -> str:
    """Escape a file path for use inside FFmpeg filter option values.

    Wraps the path in single quotes so FFmpeg's filter parser treats it
    as a literal value — no need to individually escape colons, spaces, etc.
    """
    # Use forward slashes (works on all platforms in FFmpeg)
    path = path.replace("\\", "/")
    # Escape any existing single quotes inside the path
    path = path.replace("'", "'\\''")
    return f"'{path}'"


def _wrap_text(text: str, max_chars: int = 35) -> str:
    """Word-wrap text for FFmpeg textfile (plain text, no escaping needed)."""
    words = text.split()
    lines: list[str] = []
    current_line = ""
    for word in words:
        if len(current_line) + len(word) + 1 > max_chars:
            lines.append(current_line)
            current_line = word
        else:
            current_line = f"{current_line} {word}".strip()
    if current_line:
        lines.append(current_line)
    return "\n".join(lines)


def _find_font(preferred_name: str | None = None) -> str | None:
    """Find a TTF font file for FFmpeg drawtext.

    Search order:
    1. Local font cache (previously downloaded Google Fonts)
    2. Flutter google_fonts cache directories
    3. System font directories
    4. Download from Google Fonts API (if preferred_name is a Google Font)
    """
    import os
    import glob
    import tempfile

    # Local cache for downloaded fonts
    font_cache_dir = os.path.join(tempfile.gettempdir(), "clipmaster_fonts")
    os.makedirs(font_cache_dir, exist_ok=True)

    # Check cache first
    if preferred_name:
        cached = os.path.join(font_cache_dir, f"{preferred_name}-Regular.ttf")
        if os.path.isfile(cached):
            logger.info("Using cached font: %s", cached)
            return cached

    # Flutter google_fonts cache locations
    flutter_cache_dirs = []
    if os.name == "nt":
        local_app_data = os.environ.get("LOCALAPPDATA", "")
        if local_app_data:
            flutter_cache_dirs.append(
                os.path.join(local_app_data, ".dartServer", ".google_fonts")
            )
            flutter_cache_dirs.append(
                os.path.join(local_app_data, "google_fonts")
            )
        app_data = os.environ.get("APPDATA", "")
        if app_data:
            flutter_cache_dirs.append(os.path.join(app_data, "google_fonts"))
    else:
        home = os.path.expanduser("~")
        flutter_cache_dirs.append(os.path.join(home, ".cache", "google_fonts"))

    # System font paths
    font_dirs = flutter_cache_dirs + [
        "/usr/share/fonts",
        "/usr/local/share/fonts",
        os.path.expanduser("~/.fonts"),
        os.path.expanduser("~/.local/share/fonts"),
        "/System/Library/Fonts",
        "/Library/Fonts",
        os.path.expanduser("~/Library/Fonts"),
        r"C:\Windows\Fonts",
    ]

    # User's chosen font goes first, then fallback list
    preferred = []
    if preferred_name:
        preferred.append(preferred_name)
    preferred.extend([
        "Inter", "Roboto", "Montserrat", "Poppins", "Lato", "Oswald",
        "LiberationSans", "Liberation Sans", "DejaVuSans", "DejaVu Sans",
        "NotoSans", "Noto Sans", "Arial", "Helvetica", "FreeSans",
    ])

    for font_dir in font_dirs:
        if not os.path.isdir(font_dir):
            continue
        for font_name in preferred:
            patterns = [
                os.path.join(font_dir, "**", f"{font_name}*.ttf"),
                os.path.join(font_dir, "**", f"{font_name}*.otf"),
                os.path.join(font_dir, "**", f"{font_name.replace(' ', '')}*.ttf"),
                os.path.join(font_dir, "**", f"{font_name.replace(' ', '')}*.otf"),
                os.path.join(font_dir, "**", f"{font_name.lower()}*.ttf"),
                os.path.join(font_dir, "**", f"{font_name.lower()}*.otf"),
            ]
            for pattern in patterns:
                matches = glob.glob(pattern, recursive=True)
                if matches:
                    regular = [m for m in matches
                               if "Bold" not in os.path.basename(m)
                               and "Italic" not in os.path.basename(m)
                               and "bold" not in os.path.basename(m)
                               and "italic" not in os.path.basename(m)
                               and not os.path.basename(m).lower().endswith(
                                   ("i.ttf", "i.otf", "b.ttf", "b.otf",
                                    "bi.ttf", "bi.otf", "z.ttf", "z.otf"))]
                    best = regular[0] if regular else matches[0]
                    logger.info("Using font: %s", best)
                    return best

    # Not found on system — download from Google Fonts
    if preferred_name:
        downloaded = _download_google_font(preferred_name, font_cache_dir)
        if downloaded:
            return downloaded

    logger.warning("No font found for '%s', FFmpeg will use default", preferred_name)
    return None


# Google Fonts direct download URLs (regular weight)
_GOOGLE_FONT_URLS = {
    "Inter": "https://fonts.gstatic.com/s/inter/v18/UcCO3FwrK3iLTeHuS_nVMrMxCp50SjIw2boKoduKmMEVuLyfAZ9hiA.woff2",
    "Roboto": "https://fonts.gstatic.com/s/roboto/v47/KFOMCnqEu92Fr1ME7kSn66aGLdTylUAMQXC89YmC2DPNWubEbGmT.ttf",
    "Montserrat": "https://fonts.gstatic.com/s/montserrat/v29/JTUHjIg1_i6t8kCHKm4532VJOt5-QNFgpCtr6Hw5aXo.ttf",
    "Oswald": "https://fonts.gstatic.com/s/oswald/v53/TK3_WkUHHAIjg75cFRf3bXL8LICs1_FvsUZiYA.ttf",
    "Lato": "https://fonts.gstatic.com/s/lato/v24/S6uyw4BMUTPHjx4wXg.ttf",
    "Poppins": "https://fonts.gstatic.com/s/poppins/v22/pxiEyp8kv8JHgFVrJJfecg.ttf",
}


def _download_google_font(name: str, cache_dir: str) -> str | None:
    """Download a Google Font TTF file to local cache."""
    import os
    import urllib.request

    url = _GOOGLE_FONT_URLS.get(name)
    if not url:
        # Try the Google Fonts CSS API to get the URL dynamically
        try:
            css_url = f"https://fonts.googleapis.com/css2?family={name.replace(' ', '+')}"
            req = urllib.request.Request(css_url, headers={
                "User-Agent": "Mozilla/5.0",  # Google Fonts requires a browser-like UA
            })
            with urllib.request.urlopen(req, timeout=10) as resp:
                css = resp.read().decode("utf-8")
            # Extract first TTF/woff2 URL from CSS
            import re
            match = re.search(r"url\((https://fonts\.gstatic\.com/[^)]+\.ttf)\)", css)
            if not match:
                match = re.search(r"url\((https://fonts\.gstatic\.com/[^)]+)\)", css)
            if match:
                url = match.group(1)
        except Exception as exc:
            logger.warning("Could not fetch Google Fonts CSS for %s: %s", name, exc)

    if not url:
        return None

    ext = ".woff2" if url.endswith(".woff2") else ".ttf"
    dest = os.path.join(cache_dir, f"{name}-Regular{ext}")

    try:
        logger.info("Downloading Google Font %s from %s", name, url[:80])
        urllib.request.urlretrieve(url, dest)
        if os.path.isfile(dest) and os.path.getsize(dest) > 1000:
            logger.info("Downloaded font: %s (%d bytes)", dest, os.path.getsize(dest))
            return dest
    except Exception as exc:
        logger.warning("Failed to download font %s: %s", name, exc)

    return None


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
    """Download a clip — partial extraction if start/end provided, else full download."""
    url = msg.payload.get("url", "")
    start_time = msg.payload.get("start_time")
    end_time = msg.payload.get("end_time")
    output_name = msg.payload.get("output_name")

    if not url:
        await _send(ws, IpcMessage.error(msg.id, "No URL provided."))
        return

    try:
        if start_time is not None and end_time is not None:
            # Partial clip extraction via FFmpeg stream seeking.
            result = await download_clip(
                url, start_time, end_time,
                output_name=output_name,
                on_progress=lambda pct, stage: _send(
                    ws, IpcMessage.progress(msg.id, stage, pct)),
            )
        else:
            # Full video download via yt-dlp.
            async def on_progress(pct: int, stage: str) -> None:
                await _send(ws, IpcMessage.progress(msg.id, stage, pct))

            result = await download_video(
                url, output_name=output_name, on_progress=on_progress,
            )

        await _send(ws, IpcMessage.progress(msg.id, "Complete", 100))
        await _send(ws, IpcMessage.result(msg.id, result))
    except Exception as exc:
        logger.error("Clip download failed: %s", exc)
        await _send(ws, IpcMessage.error(msg.id, f"Clip download failed: {exc}"))
