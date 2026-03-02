"""Viral Scout - Trending Video Discovery Service.

Monitors YouTube/Twitch trending pages and ranks videos by:
    - Velocity: Views / Hours Since Upload
    - Engagement Density: (Comments + Likes) / Views

Returns a ranked list of "Recommended to Clip" videos for the Flutter UI.
"""

from __future__ import annotations

import logging
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

    In production, this integrates with:
        - YouTube Data API v3 (or yt-dlp scraping as fallback)
        - Twitch Helix API for live/VOD trending
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

        # In production, this calls the real API.
        # For now, return the structure that the Flutter UI expects.
        raw_videos = await self._fetch_raw(platform, limit)
        ranked = self._rank(raw_videos)
        return [v.to_dict() for v in ranked[:limit]]

    async def _fetch_raw(self, platform: str, limit: int) -> list[TrendingVideo]:
        """Fetch raw video data from the platform.

        Production implementation would use:
            - YouTube: yt-dlp with --flat-playlist on trending URL, or YouTube Data API
            - Twitch: Helix API /videos?sort=trending
        """
        # Placeholder: returns empty list until API integration is wired.
        logger.info("_fetch_raw: platform=%s - awaiting API integration", platform)
        return []

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
