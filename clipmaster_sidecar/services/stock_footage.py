"""Stock Footage Query Service.

Queries Pexels and Pixabay APIs for B-roll video clips matching
visual keywords extracted by the ScriptAnalyzer.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

import httpx

logger = logging.getLogger("clipmaster_sidecar.stock_footage")


@dataclass
class StockClip:
    """A stock video clip result."""

    clip_id: str
    source: str  # "pexels" or "pixabay"
    url: str
    preview_url: str
    download_url: str
    width: int
    height: int
    duration: float
    keyword: str

    def to_dict(self) -> dict:
        return {
            "clip_id": self.clip_id,
            "source": self.source,
            "url": self.url,
            "preview_url": self.preview_url,
            "download_url": self.download_url,
            "width": self.width,
            "height": self.height,
            "duration": self.duration,
            "keyword": self.keyword,
        }


class StockFootageService:
    """Queries Pexels and Pixabay for stock video clips.

    Requires API keys passed from the Flutter side (BYOK).
    """

    PEXELS_BASE = "https://api.pexels.com/videos/search"
    PIXABAY_BASE = "https://pixabay.com/api/videos/"

    def __init__(self) -> None:
        self._client = httpx.AsyncClient(timeout=15.0)

    async def search(
        self,
        keyword: str,
        pexels_key: str | None = None,
        pixabay_key: str | None = None,
        per_source: int = 3,
    ) -> list[dict]:
        """Search for stock clips matching a keyword.

        Args:
            keyword: Visual search term (e.g., "cinematic nebula").
            pexels_key: Pexels API key (BYOK).
            pixabay_key: Pixabay API key (BYOK).
            per_source: Max results per source.

        Returns:
            List of StockClip dicts.
        """
        results: list[StockClip] = []

        if pexels_key:
            results.extend(await self._search_pexels(keyword, pexels_key, per_source))
        if pixabay_key:
            results.extend(await self._search_pixabay(keyword, pixabay_key, per_source))

        logger.info("Found %d clips for '%s'", len(results), keyword)
        return [c.to_dict() for c in results]

    async def _search_pexels(
        self, keyword: str, api_key: str, limit: int
    ) -> list[StockClip]:
        try:
            resp = await self._client.get(
                self.PEXELS_BASE,
                params={"query": keyword, "per_page": limit, "orientation": "portrait"},
                headers={"Authorization": api_key},
            )
            resp.raise_for_status()
            data = resp.json()

            clips: list[StockClip] = []
            for video in data.get("videos", []):
                # Pick the best quality video file.
                files = video.get("video_files", [])
                best = max(files, key=lambda f: f.get("width", 0)) if files else None
                if not best:
                    continue

                clips.append(
                    StockClip(
                        clip_id=str(video["id"]),
                        source="pexels",
                        url=video.get("url", ""),
                        preview_url=video.get("image", ""),
                        download_url=best.get("link", ""),
                        width=best.get("width", 0),
                        height=best.get("height", 0),
                        duration=video.get("duration", 0),
                        keyword=keyword,
                    )
                )
            return clips
        except Exception as exc:
            logger.error("Pexels search failed for '%s': %s", keyword, exc)
            return []

    async def _search_pixabay(
        self, keyword: str, api_key: str, limit: int
    ) -> list[StockClip]:
        try:
            resp = await self._client.get(
                self.PIXABAY_BASE,
                params={"key": api_key, "q": keyword, "per_page": limit},
            )
            resp.raise_for_status()
            data = resp.json()

            clips: list[StockClip] = []
            for hit in data.get("hits", []):
                videos = hit.get("videos", {})
                large = videos.get("large", {})

                clips.append(
                    StockClip(
                        clip_id=str(hit.get("id", "")),
                        source="pixabay",
                        url=hit.get("pageURL", ""),
                        preview_url=hit.get("userImageURL", ""),
                        download_url=large.get("url", ""),
                        width=large.get("width", 0),
                        height=large.get("height", 0),
                        duration=hit.get("duration", 0),
                        keyword=keyword,
                    )
                )
            return clips
        except Exception as exc:
            logger.error("Pixabay search failed for '%s': %s", keyword, exc)
            return []

    async def close(self) -> None:
        await self._client.aclose()
