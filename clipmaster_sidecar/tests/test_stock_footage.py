"""Tests for the Stock Footage service."""

from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, MagicMock

from clipmaster_sidecar.services.stock_footage import StockClip, StockFootageService


def _loop():
    return asyncio.get_event_loop()


def test_stock_clip_to_dict() -> None:
    clip = StockClip(
        clip_id="123", source="pexels",
        url="https://pexels.com/v/123", preview_url="https://pexels.com/preview.jpg",
        download_url="https://pexels.com/dl/123.mp4",
        width=1920, height=1080, duration=15.0, keyword="ocean",
    )
    d = clip.to_dict()
    assert d["clip_id"] == "123"
    assert d["source"] == "pexels"
    assert d["width"] == 1920
    assert d["duration"] == 15.0


def test_search_with_no_keys_returns_empty() -> None:
    service = StockFootageService()
    results = _loop().run_until_complete(service.search("sunset"))
    assert results == []


def test_search_pexels_parses_response() -> None:
    service = StockFootageService()
    mock_response = MagicMock()
    mock_response.raise_for_status = MagicMock()
    mock_response.json.return_value = {
        "videos": [{
            "id": 456, "url": "https://pexels.com/v/456",
            "image": "https://pexels.com/thumb.jpg", "duration": 20,
            "video_files": [
                {"link": "https://pexels.com/dl/sd.mp4", "width": 640, "height": 480},
                {"link": "https://pexels.com/dl/hd.mp4", "width": 1920, "height": 1080},
            ],
        }]
    }
    service._client = MagicMock()
    service._client.get = AsyncMock(return_value=mock_response)

    clips = _loop().run_until_complete(service._search_pexels("sunset", "fake-key", 3))
    assert len(clips) == 1
    assert clips[0].clip_id == "456"
    assert clips[0].download_url == "https://pexels.com/dl/hd.mp4"
    assert clips[0].width == 1920


def test_search_pixabay_parses_response() -> None:
    service = StockFootageService()
    mock_response = MagicMock()
    mock_response.raise_for_status = MagicMock()
    mock_response.json.return_value = {
        "hits": [{
            "id": 789, "pageURL": "https://pixabay.com/v/789",
            "userImageURL": "https://pixabay.com/thumb.jpg", "duration": 30,
            "videos": {"large": {"url": "https://pixabay.com/dl/789.mp4", "width": 1280, "height": 720}},
        }]
    }
    service._client = MagicMock()
    service._client.get = AsyncMock(return_value=mock_response)

    clips = _loop().run_until_complete(service._search_pixabay("mountain", "fake-key", 3))
    assert len(clips) == 1
    assert clips[0].source == "pixabay"
    assert clips[0].clip_id == "789"


def test_search_pexels_handles_api_error() -> None:
    service = StockFootageService()
    service._client = MagicMock()
    service._client.get = AsyncMock(side_effect=Exception("API down"))

    clips = _loop().run_until_complete(service._search_pexels("sunset", "fake-key", 3))
    assert clips == []


def test_search_combines_both_sources() -> None:
    service = StockFootageService()

    pexels_response = MagicMock()
    pexels_response.raise_for_status = MagicMock()
    pexels_response.json.return_value = {
        "videos": [{
            "id": 1, "url": "", "image": "", "duration": 10,
            "video_files": [{"link": "https://pexels.com/dl/1.mp4", "width": 1920, "height": 1080}],
        }]
    }

    pixabay_response = MagicMock()
    pixabay_response.raise_for_status = MagicMock()
    pixabay_response.json.return_value = {
        "hits": [{
            "id": 2, "pageURL": "", "userImageURL": "", "duration": 15,
            "videos": {"large": {"url": "https://pixabay.com/dl/2.mp4", "width": 1280, "height": 720}},
        }]
    }

    call_count = 0

    async def mock_get(*args, **kwargs):
        nonlocal call_count
        call_count += 1
        return pexels_response if call_count == 1 else pixabay_response

    service._client = MagicMock()
    service._client.get = mock_get

    results = _loop().run_until_complete(service.search("nature", pexels_key="pk", pixabay_key="xk"))
    assert len(results) == 2
    assert results[0]["source"] == "pexels"
    assert results[1]["source"] == "pixabay"
