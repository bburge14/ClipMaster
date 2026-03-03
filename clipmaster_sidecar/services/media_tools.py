"""Media processing tools using FFmpeg and yt-dlp.

Handles: video download, proxy generation, FFmpeg rendering, transcription,
and text-to-speech via cloud APIs.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import shutil
import tempfile
from pathlib import Path
from typing import Any, Callable

import httpx

logger = logging.getLogger("clipmaster_sidecar.media_tools")


def _find_binary(name: str) -> str | None:
    """Find a binary on PATH or in bundled_binaries/."""
    on_path = shutil.which(name)
    if on_path:
        return on_path
    sidecar_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    install_dir = os.path.dirname(sidecar_dir)
    exe = f"{name}.exe" if os.name == "nt" else name
    bundled = os.path.join(install_dir, "bundled_binaries", exe)
    if os.path.isfile(bundled):
        return bundled
    return None


# ---------------------------------------------------------------------------
# Video Download (yt-dlp)
# ---------------------------------------------------------------------------

async def download_video(
    url: str,
    output_dir: str | None = None,
    on_progress: Callable[[int, str], Any] | None = None,
) -> dict:
    """Download a video using yt-dlp with parallel downloading.

    Uses -N 16 for fragment-parallel downloads. If aria2c is available,
    uses it as an external downloader for even faster speeds.

    Returns dict with: file_path, title, duration, format.
    """
    ytdlp = _find_binary("yt-dlp")
    if not ytdlp:
        raise FileNotFoundError("yt-dlp not found in bundled_binaries or PATH")

    if output_dir is None:
        output_dir = os.path.join(tempfile.gettempdir(), "clipmaster_downloads")
    os.makedirs(output_dir, exist_ok=True)

    output_template = os.path.join(output_dir, "%(title)s.%(ext)s")

    cmd = [
        ytdlp,
        "--no-playlist",
        "-N", "16",  # 16-thread parallel fragment download
        "-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
        "--merge-output-format", "mp4",
        "--newline",
        "--progress",
        "-o", output_template,
        "--print-to-file", "after_move:filepath", os.path.join(output_dir, ".last_download"),
        url,
    ]

    # Use aria2c as external downloader if available (much faster).
    aria2c = _find_binary("aria2c")
    if aria2c:
        cmd[1:1] = [
            "--external-downloader", aria2c,
            "--external-downloader-args", "-x 16 -s 16 -k 1M",
        ]
        logger.info("Using aria2c for parallel download acceleration")

    if on_progress:
        await on_progress(5, "Starting download")

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )

    last_pct = 5
    async for raw_line in proc.stdout:
        line = raw_line.decode("utf-8", errors="replace").strip()
        # Parse yt-dlp progress: [download]  45.2% of ~100MiB ...
        match = re.search(r"\[download\]\s+([\d.]+)%", line)
        if match and on_progress:
            pct = min(int(float(match.group(1)) * 0.9), 90)  # scale to 5-90
            pct = max(pct, last_pct)
            last_pct = pct
            await on_progress(pct, "Downloading")

    await proc.wait()

    if proc.returncode != 0:
        raise RuntimeError(f"yt-dlp exited with code {proc.returncode}")

    # Read the output file path
    marker = os.path.join(output_dir, ".last_download")
    if os.path.isfile(marker):
        file_path = Path(marker).read_text().strip()
        os.remove(marker)
    else:
        # Fallback: find most recent mp4
        files = sorted(Path(output_dir).glob("*.mp4"), key=os.path.getmtime, reverse=True)
        file_path = str(files[0]) if files else ""

    if on_progress:
        await on_progress(95, "Finalizing")

    return {
        "file_path": file_path,
        "output_dir": output_dir,
    }


async def download_clip(
    url: str,
    start_time: str,
    end_time: str,
    output_dir: str | None = None,
    output_name: str | None = None,
    on_progress: Callable[[int, str], Any] | None = None,
) -> dict:
    """Download only a specific time range from a video (stream seeking).

    Uses FFmpeg to read directly from the stream URL provided by yt-dlp,
    extracting only the requested portion. Turns a 1-hour download into
    seconds.

    Args:
        url: Video URL (YouTube, Twitch, etc.).
        start_time: Start time in FFmpeg format (e.g. "00:05:30" or "330").
        end_time: End time in FFmpeg format.
        output_dir: Where to save the clip.
        output_name: Optional output filename (without extension).

    Returns dict with: file_path, start_time, end_time.
    """
    ytdlp = _find_binary("yt-dlp")
    ffmpeg = _find_binary("ffmpeg")
    if not ytdlp:
        raise FileNotFoundError("yt-dlp not found")
    if not ffmpeg:
        raise FileNotFoundError("ffmpeg not found")

    if output_dir is None:
        output_dir = os.path.join(tempfile.gettempdir(), "clipmaster_clips")
    os.makedirs(output_dir, exist_ok=True)

    if on_progress:
        await on_progress(10, "Resolving stream URL")

    # Step 1: Get the direct stream URL from yt-dlp.
    proc = await asyncio.create_subprocess_exec(
        ytdlp, "-g",
        "-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
        url,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()

    if proc.returncode != 0:
        raise RuntimeError(f"yt-dlp -g failed: {stderr.decode()[:300]}")

    stream_urls = stdout.decode().strip().split("\n")

    if on_progress:
        await on_progress(30, "Extracting clip from stream")

    safe_name = output_name or f"clip_{start_time.replace(':', '')}_{end_time.replace(':', '')}"
    safe_name = re.sub(r"[^\w\s-]", "", safe_name).strip().replace(" ", "_")
    output_path = os.path.join(output_dir, f"{safe_name}.mp4")

    if len(stream_urls) >= 2:
        # Separate video + audio streams — mux together.
        cmd = [
            ffmpeg, "-y",
            "-ss", start_time, "-to", end_time,
            "-i", stream_urls[0],
            "-ss", start_time, "-to", end_time,
            "-i", stream_urls[1],
            "-c", "copy",
            "-map", "0:v:0", "-map", "1:a:0",
            output_path,
        ]
    else:
        # Single combined stream.
        cmd = [
            ffmpeg, "-y",
            "-ss", start_time, "-to", end_time,
            "-i", stream_urls[0],
            "-c", "copy",
            output_path,
        ]

    proc2 = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    _, stderr2 = await proc2.communicate()

    if proc2.returncode != 0:
        raise RuntimeError(f"FFmpeg clip extraction failed: {stderr2.decode()[:300]}")

    if on_progress:
        await on_progress(95, "Clip extracted")

    return {
        "file_path": output_path,
        "start_time": start_time,
        "end_time": end_time,
    }


# ---------------------------------------------------------------------------
# Proxy Generation (FFmpeg)
# ---------------------------------------------------------------------------

async def generate_proxy(
    source_path: str,
    on_progress: Callable[[int, str], Any] | None = None,
) -> dict:
    """Generate a 720p proxy from a source video using FFmpeg.

    Returns dict with: proxy_path, width, height.
    """
    ffmpeg = _find_binary("ffmpeg")
    if not ffmpeg:
        raise FileNotFoundError("ffmpeg not found in bundled_binaries or PATH")

    if not os.path.isfile(source_path):
        raise FileNotFoundError(f"Source video not found: {source_path}")

    src = Path(source_path)
    proxy_path = str(src.parent / f"{src.stem}_720p.mp4")

    if on_progress:
        await on_progress(10, "Starting proxy generation")

    # Get duration for progress
    duration = await _get_duration(ffmpeg, source_path)

    cmd = [
        ffmpeg, "-y",
        "-i", source_path,
        "-vf", "scale=-2:720",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
        "-c:a", "aac", "-b:a", "128k",
        "-progress", "pipe:1",
        proxy_path,
    ]

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    await _track_ffmpeg_progress(proc, duration, on_progress, 10, 90)
    await proc.wait()

    if proc.returncode != 0:
        stderr = (await proc.stderr.read()).decode()
        raise RuntimeError(f"FFmpeg proxy failed: {stderr[:500]}")

    if on_progress:
        await on_progress(100, "Proxy complete")

    return {"proxy_path": proxy_path, "width": -2, "height": 720}


# ---------------------------------------------------------------------------
# FFmpeg Render (Final Export)
# ---------------------------------------------------------------------------

async def ffmpeg_render(
    inputs: list[dict],
    output_path: str,
    resolution: str = "1080x1920",
    on_progress: Callable[[int, str], Any] | None = None,
) -> dict:
    """Render a final video from a list of input clips.

    Each input dict: {file_path, start?, end?, type: "video"|"audio"|"image"}
    """
    ffmpeg = _find_binary("ffmpeg")
    if not ffmpeg:
        raise FileNotFoundError("ffmpeg not found in bundled_binaries or PATH")

    if on_progress:
        await on_progress(5, "Building render pipeline")

    w, h = resolution.split("x")

    # Simple concat: filter all video inputs into a single output
    input_args = []
    filter_parts = []

    for i, inp in enumerate(inputs):
        fp = inp.get("file_path", "")
        if not os.path.isfile(fp):
            logger.warning("Skipping missing input: %s", fp)
            continue
        input_args.extend(["-i", fp])
        filter_parts.append(
            f"[{i}:v]scale={w}:{h}:force_original_aspect_ratio=decrease,"
            f"pad={w}:{h}:(ow-iw)/2:(oh-ih)/2,setsar=1[v{i}]"
        )

    if not input_args:
        raise ValueError("No valid input files provided")

    n = len(input_args) // 2
    concat_inputs = "".join(f"[v{i}]" for i in range(n))
    filter_complex = ";".join(filter_parts) + f";{concat_inputs}concat=n={n}:v=1:a=0[outv]"

    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)

    cmd = [
        ffmpeg, "-y",
        *input_args,
        "-filter_complex", filter_complex,
        "-map", "[outv]",
        "-c:v", "libx264", "-preset", "medium", "-crf", "18",
        "-pix_fmt", "yuv420p",
        "-progress", "pipe:1",
        output_path,
    ]

    if on_progress:
        await on_progress(15, "Encoding video")

    # Estimate total duration
    total_duration = 0.0
    for inp in inputs:
        dur = await _get_duration(ffmpeg, inp.get("file_path", ""))
        total_duration += dur

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    await _track_ffmpeg_progress(proc, total_duration, on_progress, 15, 90)
    await proc.wait()

    if proc.returncode != 0:
        stderr = (await proc.stderr.read()).decode()
        raise RuntimeError(f"FFmpeg render failed: {stderr[:500]}")

    if on_progress:
        await on_progress(100, "Render complete")

    return {"output_path": output_path, "resolution": resolution}


# ---------------------------------------------------------------------------
# Transcription (OpenAI Whisper API)
# ---------------------------------------------------------------------------

async def transcribe_audio(
    audio_path: str,
    api_key: str,
    on_progress: Callable[[int, str], Any] | None = None,
) -> dict:
    """Transcribe audio using OpenAI's Whisper API.

    Returns dict with: segments [{start, end, text}], full_text.
    """
    if not os.path.isfile(audio_path):
        raise FileNotFoundError(f"Audio file not found: {audio_path}")

    if on_progress:
        await on_progress(10, "Preparing audio")

    # Extract audio to a temp wav if it's a video file
    ffmpeg = _find_binary("ffmpeg")
    temp_audio = None
    ext = os.path.splitext(audio_path)[1].lower()
    if ext in (".mp4", ".mkv", ".avi", ".mov", ".webm"):
        if not ffmpeg:
            raise FileNotFoundError("ffmpeg needed to extract audio from video")
        temp_audio = os.path.join(tempfile.gettempdir(), "clipmaster_whisper_input.mp3")
        proc = await asyncio.create_subprocess_exec(
            ffmpeg, "-y", "-i", audio_path,
            "-vn", "-acodec", "libmp3lame", "-q:a", "4",
            temp_audio,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await proc.wait()
        if proc.returncode != 0:
            raise RuntimeError("Failed to extract audio from video")
        audio_path = temp_audio

    if on_progress:
        await on_progress(30, "Sending to Whisper API")

    async with httpx.AsyncClient(timeout=300.0) as client:
        with open(audio_path, "rb") as f:
            resp = await client.post(
                "https://api.openai.com/v1/audio/transcriptions",
                headers={"Authorization": f"Bearer {api_key}"},
                files={"file": (os.path.basename(audio_path), f, "audio/mpeg")},
                data={
                    "model": "whisper-1",
                    "response_format": "verbose_json",
                    "timestamp_granularity": "segment",
                },
            )

    if temp_audio and os.path.isfile(temp_audio):
        os.remove(temp_audio)

    if on_progress:
        await on_progress(80, "Processing transcript")

    resp.raise_for_status()
    data = resp.json()

    segments = [
        {
            "start": seg.get("start", 0),
            "end": seg.get("end", 0),
            "text": seg.get("text", "").strip(),
        }
        for seg in data.get("segments", [])
    ]

    full_text = data.get("text", "")

    if on_progress:
        await on_progress(100, "Transcription complete")

    return {"segments": segments, "full_text": full_text}


# ---------------------------------------------------------------------------
# Text-to-Speech (OpenAI TTS API)
# ---------------------------------------------------------------------------

async def generate_tts(
    text: str,
    api_key: str,
    voice: str = "alloy",
    output_dir: str | None = None,
    on_progress: Callable[[int, str], Any] | None = None,
) -> dict:
    """Generate speech from text using OpenAI's TTS API.

    Voices: alloy, echo, fable, onyx, nova, shimmer.
    Returns dict with: audio_path, voice, duration_estimate.
    """
    if output_dir is None:
        output_dir = os.path.join(tempfile.gettempdir(), "clipmaster_tts")
    os.makedirs(output_dir, exist_ok=True)

    if on_progress:
        await on_progress(10, "Sending to TTS API")

    async with httpx.AsyncClient(timeout=120.0) as client:
        resp = await client.post(
            "https://api.openai.com/v1/audio/speech",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            json={
                "model": "tts-1",
                "input": text,
                "voice": voice,
                "response_format": "mp3",
            },
        )
        resp.raise_for_status()

    if on_progress:
        await on_progress(70, "Saving audio file")

    # Save the audio
    safe_name = re.sub(r"[^\w\s-]", "", text[:40]).strip().replace(" ", "_")
    audio_path = os.path.join(output_dir, f"tts_{safe_name}_{voice}.mp3")

    with open(audio_path, "wb") as f:
        f.write(resp.content)

    # Rough duration estimate: ~150 words per minute
    word_count = len(text.split())
    duration_estimate = (word_count / 150) * 60

    if on_progress:
        await on_progress(100, "TTS complete")

    return {
        "audio_path": audio_path,
        "voice": voice,
        "duration_estimate": round(duration_estimate, 1),
    }


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

async def _get_duration(ffmpeg: str, file_path: str) -> float:
    """Get video duration in seconds using ffprobe."""
    ffprobe = _find_binary("ffprobe") or ffmpeg.replace("ffmpeg", "ffprobe")
    try:
        proc = await asyncio.create_subprocess_exec(
            ffprobe,
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "json",
            file_path,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await proc.communicate()
        data = json.loads(stdout.decode())
        return float(data.get("format", {}).get("duration", 0))
    except Exception:
        return 60.0  # Default fallback


async def _track_ffmpeg_progress(
    proc: asyncio.subprocess.Process,
    total_duration: float,
    on_progress: Callable[[int, str], Any] | None,
    min_pct: int,
    max_pct: int,
) -> None:
    """Track FFmpeg progress from -progress pipe:1 output."""
    if not on_progress or not proc.stdout or total_duration <= 0:
        return

    pct_range = max_pct - min_pct
    async for raw_line in proc.stdout:
        line = raw_line.decode("utf-8", errors="replace").strip()
        if line.startswith("out_time_us="):
            try:
                us = int(line.split("=")[1])
                seconds = us / 1_000_000
                ratio = min(seconds / total_duration, 1.0)
                pct = min_pct + int(ratio * pct_range)
                await on_progress(pct, "Encoding")
            except (ValueError, IndexError):
                pass
