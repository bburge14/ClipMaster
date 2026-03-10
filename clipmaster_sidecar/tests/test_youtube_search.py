"""Tests for the YouTube Search service."""

from __future__ import annotations

import asyncio
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock

import httpx
import pytest

from clipmaster_sidecar.services.youtube_search import YouTubeSearchService, YouTubeVideo


def _loop():
    return asyncio.get_event_loop()


def test_youtube_video_to_dict() -> None:
    v = YouTubeVideo(
        video_id="abc123", title="Test Video", channel="TestChan",
        views=100000, likes=5000, comments=500,
        uploaded_at=datetime(2026, 1, 1, tzinfo=timezone.utc),
        thumbnail_url="https://img.youtube.com/vi/abc123/hqdefault.jpg",
        url="https://www.youtube.com/watch?v=abc123",
    )
    d = v.to_dict()
    assert d["video_id"] == "abc123"
    assert d["platform"] == "youtube"
    assert d["views"] == 100000


def test_ranking_sorts_by_composite_score() -> None:
    service = YouTubeSearchService()
    now = datetime.now(timezone.utc)
    fast = YouTubeVideo(
        video_id="fast", title="Fast", channel="C", views=1_000_000,
        likes=5000, comments=1000, uploaded_at=now, thumbnail_url="", url="",
    )
    slow = YouTubeVideo(
        video_id="slow", title="Slow", channel="C", views=100,
        likes=1, comments=0, uploaded_at=now, thumbnail_url="", url="",
    )
    ranked = service._rank([slow, fast])
    assert ranked[0].video_id == "fast"
    assert ranked[0].composite_score > ranked[1].composite_score


def test_ranking_empty_list() -> None:
    service = YouTubeSearchService()
    assert service._rank([]) == []


def test_parse_videos() -> None:
    service = YouTubeSearchService()
    data = {
        "items": [{
            "id": "vid1",
            "snippet": {
                "title": "Video 1", "channelTitle": "Channel 1",
                "publishedAt": "2026-01-15T10:00:00Z",
                "thumbnails": {"high": {"url": "https://thumb.jpg"}},
            },
            "statistics": {"viewCount": "50000", "likeCount": "2000", "commentCount": "300"},
        }]
    }
    videos = service._parse_videos(data)
    assert len(videos) == 1
    assert videos[0].video_id == "vid1"
    assert videos[0].views == 50000
    assert videos[0].likes == 2000


def test_search_trending_calls_api() -> None:
    service = YouTubeSearchService()
    mock_response = MagicMock()
    mock_response.raise_for_status = MagicMock()
    mock_response.json.return_value = {
        "items": [{
            "id": "t1",
            "snippet": {
                "title": "Trending 1", "channelTitle": "Chan",
                "publishedAt": "2026-03-01T12:00:00Z",
                "thumbnails": {"high": {"url": "https://thumb.jpg"}},
            },
            "statistics": {"viewCount": "1000000", "likeCount": "50000", "commentCount": "5000"},
        }]
    }
    service._client = MagicMock()
    service._client.get = AsyncMock(return_value=mock_response)

    results = _loop().run_until_complete(service.search_trending(api_key="fake-key", limit=10))
    assert len(results) == 1
    assert results[0]["video_id"] == "t1"


def test_search_trending_403_raises_value_error() -> None:
    service = YouTubeSearchService()
    mock_response = MagicMock()
    mock_response.status_code = 403
    mock_response.raise_for_status.side_effect = httpx.HTTPStatusError(
        "Forbidden", request=MagicMock(), response=mock_response,
    )
    service._client = MagicMock()
    service._client.get = AsyncMock(return_value=mock_response)

    with pytest.raises(ValueError, match="403"):
        _loop().run_until_complete(service.search_trending(api_key="bad-key"))
