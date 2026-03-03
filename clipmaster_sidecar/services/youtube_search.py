"""YouTube Data API v3 integration for Viral Scout.

Uses the YouTube Data API to search for trending/popular videos
instead of yt-dlp scraping, which is unreliable.

Requires a YouTube Data API key (free tier: 10,000 units/day).
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timezone

import httpx

logger = logging.getLogger("clipmaster_sidecar.youtube_search")

YOUTUBE_API_BASE = "https://www.googleapis.com/youtube/v3"


@dataclass
class YouTubeVideo:
    video_id: str
    title: str
    channel: str
    views: int
    likes: int
    comments: int
    uploaded_at: datetime
    thumbnail_url: str
    url: str
    platform: str = "youtube"

    # Computed scores
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


class YouTubeSearchService:
    """Fetches trending/popular videos using YouTube Data API v3."""

    VELOCITY_WEIGHT = 0.6
    ENGAGEMENT_WEIGHT = 0.4

    def __init__(self) -> None:
        self._client = httpx.AsyncClient(timeout=15.0)

    async def search_trending(
        self,
        api_key: str,
        region: str = "US",
        limit: int = 20,
        category: str = "",
    ) -> list[dict]:
        """Fetch most popular videos for a region using the API.

        Args:
            api_key: YouTube Data API v3 key.
            region: ISO 3166-1 alpha-2 country code.
            limit: Max results (max 50 per API call).
            category: Optional video category ID (e.g., "10" for Music).
        """
        try:
            params: dict = {
                "part": "snippet,statistics",
                "chart": "mostPopular",
                "regionCode": region,
                "maxResults": min(limit, 50),
                "key": api_key,
            }
            if category:
                params["videoCategoryId"] = category

            resp = await self._client.get(
                f"{YOUTUBE_API_BASE}/videos", params=params
            )
            resp.raise_for_status()
            data = resp.json()

            videos = self._parse_videos(data)
            ranked = self._rank(videos)
            return [v.to_dict() for v in ranked[:limit]]

        except httpx.HTTPStatusError as exc:
            if exc.response.status_code == 403:
                logger.error("YouTube API quota exceeded or key invalid")
                raise ValueError(
                    "YouTube API returned 403. Your API key may be invalid, "
                    "or you've exceeded the daily quota (10,000 units). "
                    "Check your Google Cloud Console."
                ) from exc
            raise
        except Exception as exc:
            logger.error("YouTube API search failed: %s", exc)
            raise

    async def search_videos(
        self,
        api_key: str,
        query: str,
        limit: int = 20,
        order: str = "viewCount",
    ) -> list[dict]:
        """Search YouTube for videos matching a query.

        Args:
            api_key: YouTube Data API v3 key.
            query: Search query string.
            limit: Max results.
            order: Sort order — viewCount, date, rating, relevance.
        """
        try:
            # Step 1: Search for video IDs.
            search_resp = await self._client.get(
                f"{YOUTUBE_API_BASE}/search",
                params={
                    "part": "snippet",
                    "q": query,
                    "type": "video",
                    "order": order,
                    "maxResults": min(limit, 50),
                    "key": api_key,
                },
            )
            search_resp.raise_for_status()
            search_data = search_resp.json()

            video_ids = [
                item["id"]["videoId"]
                for item in search_data.get("items", [])
                if "videoId" in item.get("id", {})
            ]

            if not video_ids:
                return []

            # Step 2: Get full statistics for each video.
            stats_resp = await self._client.get(
                f"{YOUTUBE_API_BASE}/videos",
                params={
                    "part": "snippet,statistics",
                    "id": ",".join(video_ids),
                    "key": api_key,
                },
            )
            stats_resp.raise_for_status()
            stats_data = stats_resp.json()

            videos = self._parse_videos(stats_data)
            ranked = self._rank(videos)
            return [v.to_dict() for v in ranked[:limit]]

        except httpx.HTTPStatusError as exc:
            if exc.response.status_code == 403:
                raise ValueError(
                    "YouTube API returned 403. Your API key may be invalid, "
                    "or you've exceeded the daily quota."
                ) from exc
            raise

    def _parse_videos(self, data: dict) -> list[YouTubeVideo]:
        now = datetime.now(timezone.utc)
        videos = []

        for item in data.get("items", []):
            snippet = item.get("snippet", {})
            stats = item.get("statistics", {})

            published = snippet.get("publishedAt", "")
            try:
                uploaded = datetime.fromisoformat(
                    published.replace("Z", "+00:00")
                )
            except (ValueError, AttributeError):
                uploaded = now

            thumbnails = snippet.get("thumbnails", {})
            thumb = (
                thumbnails.get("high", {}).get("url", "")
                or thumbnails.get("medium", {}).get("url", "")
                or thumbnails.get("default", {}).get("url", "")
            )

            videos.append(
                YouTubeVideo(
                    video_id=item.get("id", ""),
                    title=snippet.get("title", "Unknown"),
                    channel=snippet.get("channelTitle", "Unknown"),
                    views=int(stats.get("viewCount", 0)),
                    likes=int(stats.get("likeCount", 0)),
                    comments=int(stats.get("commentCount", 0)),
                    uploaded_at=uploaded,
                    thumbnail_url=thumb,
                    url=f"https://www.youtube.com/watch?v={item.get('id', '')}",
                )
            )
        return videos

    def _rank(self, videos: list[YouTubeVideo]) -> list[YouTubeVideo]:
        now = datetime.now(timezone.utc)
        for v in videos:
            hours = max((now - v.uploaded_at).total_seconds() / 3600, 1.0)
            v.velocity_score = v.views / hours
            v.engagement_density = (v.likes + v.comments) / max(v.views, 1)

        if not videos:
            return []

        max_vel = max(v.velocity_score for v in videos) or 1.0
        max_eng = max(v.engagement_density for v in videos) or 1.0

        for v in videos:
            v.composite_score = (
                self.VELOCITY_WEIGHT * (v.velocity_score / max_vel)
                + self.ENGAGEMENT_WEIGHT * (v.engagement_density / max_eng)
            )

        videos.sort(key=lambda v: v.composite_score, reverse=True)
        return videos

    async def close(self) -> None:
        await self._client.aclose()
