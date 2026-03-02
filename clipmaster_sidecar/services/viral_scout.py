"""Viral Scout - Trending Video Discovery Service.

Monitors YouTube/Twitch trending pages and ranks videos by:
    - Velocity: Views / Hours Since Upload
    - Engagement Density: (Comments + Likes) / Views

Returns a ranked list of "Recommended to Clip" videos for the Flutter UI.
"""

from __future__ import annotations

import asyncio
import json
import logging
import shutil
from dataclasses import dataclass, field
from datetime import datetime, timezone

logger = logging.getLogger("clipmaster_sidecar.viral_scout")


@dataclass
class TrendingVideo:
    """A ranked trending video entry."""

    video_id: str
    title: str
    url: str
    platform: str
    channel: str
    views: int
    likes: int
    comments: int
    uploaded_at: datetime
    thumbnail_url: str = ""

    # Computed scores.
    velocity_score: float = 0.0
    engagement_density: float = 0.0
    composite_score: float = 0.0

    def to_dict(self) -> dict:
        return {
            "video_id": self.video_id,
            "title": self.title,
            "url": self.url,
            "platform": self.platform,
            "channel": self.channel,
            "views": self.views,
            "likes": self.likes,
            "comments": self.comments,
            "uploaded_at": self.uploaded_at.isoformat(),
            "thumbnail_url": self.thumbnail_url,
            "velocity_score": round(self.velocity_score, 2),
            "engagement_density": round(self.engagement_density, 4),
            "composite_score": round(self.composite_score, 2),
        }


class ViralScout:
    """Discovers and ranks trending videos for clip potential.

    Scoring Algorithm:
        velocity = views / max(hours_since_upload, 1)
        engagement_density = (likes + comments) / max(views, 1)
        composite = (0.6 * normalized_velocity) + (0.4 * normalized_engagement)

    Uses yt-dlp (bundled or on PATH) to scrape YouTube trending.
    No API key required for YouTube.
    """

    # Weights for the composite score.
    VELOCITY_WEIGHT = 0.6
    ENGAGEMENT_WEIGHT = 0.4

    async def fetch_trending(
        self,
        platform: str = "youtube",
        limit: int = 20,
    ) -> list[dict]:
        """Fetch and rank trending videos.

        Args:
            platform: "youtube" or "twitch".
            limit: Max number of results to return.

        Returns:
            List of TrendingVideo dicts, sorted by composite score descending.
        """
        logger.info("Fetching trending from %s (limit=%d)", platform, limit)

        raw_videos = await self._fetch_raw(platform, limit)
        ranked = self._rank(raw_videos)
        return [v.to_dict() for v in ranked[:limit]]

    async def _fetch_raw(self, platform: str, limit: int) -> list[TrendingVideo]:
        """Fetch raw video data using yt-dlp."""
        if platform == "youtube":
            return await self._fetch_youtube_trending(limit)
        elif platform == "twitch":
            logger.info("Twitch trending requires Helix API key (not yet configured).")
            return []
        else:
            logger.warning("Unknown platform: %s", platform)
            return []

    async def _fetch_youtube_trending(self, limit: int) -> list[TrendingVideo]:
        """Fetch YouTube trending videos via yt-dlp.

        Uses --flat-playlist to quickly grab video metadata from the
        trending page, then fetches full metadata for each video to get
        view counts, likes, and comments.
        """
        ytdlp = shutil.which("yt-dlp")
        if not ytdlp:
            logger.error("yt-dlp not found on PATH or in bundled_binaries/.")
            return []

        # Step 1: Get video IDs from the trending page.
        cmd = [
            ytdlp,
            "--flat-playlist",
            "-J",
            "--playlist-end", str(limit),
            "https://www.youtube.com/feed/trending",
        ]

        logger.info("Running: %s", " ".join(cmd))

        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=60)
        except asyncio.TimeoutError:
            logger.error("yt-dlp timed out fetching trending page")
            return []
        except Exception as exc:
            logger.error("yt-dlp failed to start: %s", exc)
            return []

        if proc.returncode != 0:
            logger.error("yt-dlp exited %d: %s", proc.returncode, stderr.decode()[:500])
            return []

        try:
            data = json.loads(stdout.decode())
        except json.JSONDecodeError:
            logger.error("Failed to parse yt-dlp JSON output")
            return []

        entries = data.get("entries", [])
        if not entries:
            logger.warning("yt-dlp returned no entries from trending page")
            return []

        # Step 2: Get full metadata for each video (view count, likes, etc.).
        # Use batch mode for efficiency.
        video_ids = [e.get("id", "") for e in entries if e.get("id")][:limit]
        if not video_ids:
            return []

        urls = [f"https://www.youtube.com/watch?v={vid}" for vid in video_ids]

        batch_cmd = [
            ytdlp,
            "--skip-download",
            "-J",
            "--no-warnings",
        ] + urls

        try:
            proc2 = await asyncio.create_subprocess_exec(
                *batch_cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout2, stderr2 = await asyncio.wait_for(proc2.communicate(), timeout=120)
        except asyncio.TimeoutError:
            logger.error("yt-dlp timed out fetching video metadata")
            # Fall back to flat-playlist data only.
            return self._parse_flat_entries(entries)
        except Exception as exc:
            logger.error("yt-dlp metadata fetch failed: %s", exc)
            return self._parse_flat_entries(entries)

        if proc2.returncode != 0:
            logger.warning("yt-dlp metadata batch exited %d, using flat data", proc2.returncode)
            return self._parse_flat_entries(entries)

        # yt-dlp -J with multiple URLs outputs a JSON object with "entries" key.
        try:
            batch_data = json.loads(stdout2.decode())
            video_entries = batch_data.get("entries", [batch_data])
        except json.JSONDecodeError:
            # Sometimes yt-dlp outputs one JSON per line for multiple URLs.
            video_entries = []
            for line in stdout2.decode().strip().split("\n"):
                try:
                    video_entries.append(json.loads(line))
                except json.JSONDecodeError:
                    continue

        videos = []
        now = datetime.now(timezone.utc)
        for entry in video_entries:
            if not entry.get("id"):
                continue
            uploaded = self._parse_upload_date(entry.get("upload_date"), now)
            videos.append(
                TrendingVideo(
                    video_id=entry.get("id", ""),
                    title=entry.get("title", "Unknown"),
                    url=entry.get("webpage_url", f"https://www.youtube.com/watch?v={entry.get('id', '')}"),
                    platform="youtube",
                    channel=entry.get("uploader", entry.get("channel", "Unknown")),
                    views=entry.get("view_count") or 0,
                    likes=entry.get("like_count") or 0,
                    comments=entry.get("comment_count") or 0,
                    uploaded_at=uploaded,
                    thumbnail_url=entry.get("thumbnail", ""),
                )
            )
        return videos

    def _parse_flat_entries(self, entries: list[dict]) -> list[TrendingVideo]:
        """Parse flat-playlist entries (limited metadata) as a fallback."""
        now = datetime.now(timezone.utc)
        videos = []
        for entry in entries:
            if not entry.get("id"):
                continue
            uploaded = self._parse_upload_date(entry.get("upload_date"), now)
            videos.append(
                TrendingVideo(
                    video_id=entry.get("id", ""),
                    title=entry.get("title", "Unknown"),
                    url=entry.get("url", f"https://www.youtube.com/watch?v={entry.get('id', '')}"),
                    platform="youtube",
                    channel=entry.get("uploader", entry.get("channel", "Unknown")),
                    views=entry.get("view_count") or 0,
                    likes=entry.get("like_count") or 0,
                    comments=entry.get("comment_count") or 0,
                    uploaded_at=uploaded,
                    thumbnail_url=entry.get("thumbnail", ""),
                )
            )
        return videos

    @staticmethod
    def _parse_upload_date(date_str: str | None, fallback: datetime) -> datetime:
        """Parse yt-dlp upload_date (YYYYMMDD) into a datetime."""
        if not date_str:
            return fallback
        try:
            return datetime.strptime(date_str, "%Y%m%d").replace(tzinfo=timezone.utc)
        except ValueError:
            return fallback

    def _rank(self, videos: list[TrendingVideo]) -> list[TrendingVideo]:
        """Score and rank videos by viral clip potential."""
        now = datetime.now(timezone.utc)

        for video in videos:
            hours_since = max(
                (now - video.uploaded_at).total_seconds() / 3600, 1.0
            )
            video.velocity_score = video.views / hours_since
            video.engagement_density = (
                (video.likes + video.comments) / max(video.views, 1)
            )

        # Normalize scores to 0-1 range.
        if not videos:
            return []

        max_velocity = max(v.velocity_score for v in videos) or 1.0
        max_engagement = max(v.engagement_density for v in videos) or 1.0

        for video in videos:
            norm_velocity = video.velocity_score / max_velocity
            norm_engagement = video.engagement_density / max_engagement
            video.composite_score = (
                self.VELOCITY_WEIGHT * norm_velocity
                + self.ENGAGEMENT_WEIGHT * norm_engagement
            )

        videos.sort(key=lambda v: v.composite_score, reverse=True)
        return videos

    def score_single(self, video: TrendingVideo) -> TrendingVideo:
        """Score a single video (for the WebView 'Analyze' button)."""
        now = datetime.now(timezone.utc)
        hours_since = max(
            (now - video.uploaded_at).total_seconds() / 3600, 1.0
        )
        video.velocity_score = video.views / hours_since
        video.engagement_density = (
            (video.likes + video.comments) / max(video.views, 1)
        )
        video.composite_score = (
            self.VELOCITY_WEIGHT * (video.velocity_score / 100000)  # rough normalization
            + self.ENGAGEMENT_WEIGHT * video.engagement_density
        )
        return video
