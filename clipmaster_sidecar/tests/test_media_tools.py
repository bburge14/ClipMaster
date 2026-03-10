"""Tests for media_tools utility functions."""

from __future__ import annotations

from clipmaster_sidecar.services.media_tools import (
    get_cookie_browser,
    set_cookie_browser,
    ytdlp_cookie_args,
)


def test_cookie_browser_default_none() -> None:
    # Reset state
    set_cookie_browser(None)
    assert get_cookie_browser() is None


def test_set_cookie_browser() -> None:
    set_cookie_browser("Chrome")
    assert get_cookie_browser() == "chrome"  # lowercased

    set_cookie_browser("Firefox")
    assert get_cookie_browser() == "firefox"


def test_set_cookie_browser_strips_whitespace() -> None:
    set_cookie_browser("  Edge  ")
    assert get_cookie_browser() == "edge"


def test_set_cookie_browser_none_clears() -> None:
    set_cookie_browser("chrome")
    assert get_cookie_browser() == "chrome"
    set_cookie_browser(None)
    assert get_cookie_browser() is None


def test_set_cookie_browser_empty_clears() -> None:
    set_cookie_browser("chrome")
    set_cookie_browser("")
    assert get_cookie_browser() is None


def test_ytdlp_cookie_args_when_set() -> None:
    set_cookie_browser("chrome")
    args = ytdlp_cookie_args()
    assert args == ["--cookies-from-browser", "chrome"]


def test_ytdlp_cookie_args_when_none() -> None:
    set_cookie_browser(None)
    args = ytdlp_cookie_args()
    assert args == []
