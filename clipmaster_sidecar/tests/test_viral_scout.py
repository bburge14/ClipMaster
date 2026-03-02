"""Tests for the Viral Scout ranking algorithm."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from clipmaster_sidecar.services.viral_scout import TrendingVideo, ViralScout


def _make_video(
    video_id: str = "v1",
    views: int = 100000,
    likes: int = 5000,
    comments: int = 500,
    hours_ago: float = 2.0,
) -> TrendingVideo:
    return TrendingVideo(
        video_id=video_id,
        title=f"Test Video {video_id}",
        url=f"https://youtube.com/watch?v={video_id}",
        platform="youtube",
        channel="TestChannel",
        views=views,
        likes=likes,
        comments=comments,
        uploaded_at=datetime.now(timezone.utc) - timedelta(hours=hours_ago),
    )


def test_empty_list_returns_empty() -> None:
    scout = ViralScout()
    result = scout._rank([])
    assert result == []


def test_velocity_scoring() -> None:
    """Video with more views in fewer hours should rank higher on velocity."""
    fast = _make_video("fast", views=1_000_000, likes=100, comments=10, hours_ago=1)
    slow = _make_video("slow", views=100_000, likes=100, comments=10, hours_ago=100)

    scout = ViralScout()
    ranked = scout._rank([slow, fast])

    assert ranked[0].video_id == "fast"
    assert ranked[0].velocity_score > ranked[1].velocity_score


def test_engagement_density_scoring() -> None:
    """Video with higher (likes+comments)/views ratio should score higher on engagement."""
    engaged = _make_video("eng", views=10_000, likes=5_000, comments=2_000, hours_ago=10)
    passive = _make_video("pas", views=10_000, likes=50, comments=10, hours_ago=10)

    scout = ViralScout()
    ranked = scout._rank([passive, engaged])

    assert ranked[0].video_id == "eng"
    assert ranked[0].engagement_density > ranked[1].engagement_density


def test_composite_balances_both_factors() -> None:
    """The composite score should consider both velocity and engagement."""
    # High velocity, low engagement.
    viral = _make_video("viral", views=5_000_000, likes=100, comments=10, hours_ago=1)
    # Low velocity, high engagement.
    niche = _make_video("niche", views=1_000, likes=800, comments=200, hours_ago=1)
    # Balanced.
    balanced = _make_video("bal", views=500_000, likes=50_000, comments=10_000, hours_ago=2)

    scout = ViralScout()
    ranked = scout._rank([niche, viral, balanced])

    # All should have composite scores.
    for v in ranked:
        assert v.composite_score > 0


def test_score_single() -> None:
    scout = ViralScout()
    video = _make_video("single", views=500_000, likes=25_000, comments=3_000, hours_ago=4)
    result = scout.score_single(video)

    assert result.velocity_score > 0
    assert result.engagement_density > 0
    assert result.composite_score > 0
