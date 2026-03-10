"""Tests for the Twitch Search service."""

from __future__ import annotations

import asyncio
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock

from clipmaster_sidecar.services.twitch_search import TwitchClip, TwitchSearchService


def _loop():
    return asyncio.get_event_loop()


def test_twitch_clip_to_dict() -> None:
    clip = TwitchClip(
        clip_id="clip1", title="Epic Play", channel="streamer1",
        views=50000, likes=0, comments=0,
        created_at=datetime(2026, 3, 1, tzinfo=timezone.utc),
        thumbnail_url="https://clips.twitch.tv/thumb.jpg",
        url="https://clips.twitch.tv/clip1",
        game_name="Valorant", duration=30.0,
    )
    d = clip.to_dict()
    assert d["video_id"] == "clip1"
    assert d["platform"] == "twitch"
    assert d["views"] == 50000
    assert d["channel"] == "streamer1"


def test_parse_clip() -> None:
    item = {
        "id": "clip2", "title": "Amazing Clutch", "broadcaster_name": "pro_player",
        "view_count": 100000, "created_at": "2026-03-05T15:30:00Z",
        "thumbnail_url": "https://clips.twitch.tv/thumb2.jpg",
        "url": "https://clips.twitch.tv/clip2", "duration": 25.5,
    }
    clip = TwitchSearchService._parse_clip(item, game_name="CS2")
    assert clip.clip_id == "clip2"
    assert clip.channel == "pro_player"
    assert clip.views == 100000
    assert clip.game_name == "CS2"
    assert clip.duration == 25.5


def test_parse_clip_handles_bad_date() -> None:
    item = {
        "id": "clip3", "title": "Test", "broadcaster_name": "test",
        "view_count": 100, "created_at": "not-a-date",
        "thumbnail_url": "", "url": "",
    }
    clip = TwitchSearchService._parse_clip(item)
    assert clip.created_at.tzinfo == timezone.utc


def test_ranking_sorts_by_views() -> None:
    service = TwitchSearchService()
    now = datetime.now(timezone.utc)
    high = TwitchClip(
        clip_id="high", title="High", channel="C", views=100000,
        likes=0, comments=0, created_at=now, thumbnail_url="", url="",
    )
    low = TwitchClip(
        clip_id="low", title="Low", channel="C", views=100,
        likes=0, comments=0, created_at=now, thumbnail_url="", url="",
    )
    ranked = service._rank([low, high])
    assert ranked[0].clip_id == "high"


def test_ranking_empty_list() -> None:
    service = TwitchSearchService()
    assert service._rank([]) == []


def test_get_app_token() -> None:
    service = TwitchSearchService()
    mock_response = MagicMock()
    mock_response.raise_for_status = MagicMock()
    mock_response.json.return_value = {"access_token": "test_token_123", "expires_in": 3600}
    service._client = MagicMock()
    service._client.post = AsyncMock(return_value=mock_response)

    token = _loop().run_until_complete(service._get_app_token("client_id", "client_secret"))
    assert token == "test_token_123"


def test_get_app_token_caches() -> None:
    service = TwitchSearchService()
    mock_response = MagicMock()
    mock_response.raise_for_status = MagicMock()
    mock_response.json.return_value = {"access_token": "cached_token", "expires_in": 3600}
    service._client = MagicMock()
    service._client.post = AsyncMock(return_value=mock_response)

    token1 = _loop().run_until_complete(service._get_app_token("cid", "cs"))
    token2 = _loop().run_until_complete(service._get_app_token("cid", "cs"))
    assert token1 == token2
    assert service._client.post.call_count == 1


def test_headers() -> None:
    service = TwitchSearchService()
    headers = service._headers("my_client_id", "my_token")
    assert headers["Client-Id"] == "my_client_id"
    assert headers["Authorization"] == "Bearer my_token"
