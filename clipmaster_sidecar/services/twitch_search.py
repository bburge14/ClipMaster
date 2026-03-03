"""Twitch Helix API integration for Viral Scout.

Fetches trending clips from top games using the Twitch Helix API.
Uses client credentials (app access token) — no user login required.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import httpx

logger = logging.getLogger("clipmaster_sidecar.twitch_search")

TWITCH_AUTH_URL = "https://id.twitch.tv/oauth2/token"
TWITCH_HELIX_BASE = "https://api.twitch.tv/helix"


@dataclass
class TwitchClip:
    clip_id: str
    title: str
    channel: str
    views: int
    likes: int
    comments: int
    created_at: datetime
    thumbnail_url: str
    url: str
    game_name: str = ""
    duration: float = 0.0
    platform: str = "twitch"

    # Computed scores
    velocity_score: float = 0.0
    engagement_density: float = 0.0
    composite_score: float = 0.0

    def to_dict(self) -> dict:
        return {
            "video_id": self.clip_id,
            "title": self.title,
            "url": self.url,
            "platform": self.platform,
            "channel": self.channel,
            "views": self.views,
            "likes": self.likes,
            "comments": self.comments,
            "uploaded_at": self.created_at.isoformat(),
            "thumbnail_url": self.thumbnail_url,
            "velocity_score": round(self.velocity_score, 2),
            "engagement_density": round(self.engagement_density, 4),
            "composite_score": round(self.composite_score, 2),
        }


class TwitchSearchService:
    """Fetches trending clips from Twitch using the Helix API."""

    VELOCITY_WEIGHT = 0.6
    ENGAGEMENT_WEIGHT = 0.4

    def __init__(self) -> None:
        self._client = httpx.AsyncClient(timeout=15.0)
        self._app_token: str | None = None
        self._token_expires_at: datetime | None = None

    async def _get_app_token(self, client_id: str, client_secret: str) -> str:
        """Get or refresh an app access token via client credentials."""
        if (
            self._app_token
            and self._token_expires_at
            and datetime.now(timezone.utc) < self._token_expires_at
        ):
            return self._app_token

        resp = await self._client.post(
            TWITCH_AUTH_URL,
            params={
                "client_id": client_id,
                "client_secret": client_secret,
                "grant_type": "client_credentials",
            },
        )
        resp.raise_for_status()
        data = resp.json()

        self._app_token = data["access_token"]
        expires_in = data.get("expires_in", 3600)
        self._token_expires_at = datetime.now(timezone.utc) + timedelta(
            seconds=expires_in - 60
        )
        logger.info("Obtained Twitch app access token (expires in %ds)", expires_in)
        return self._app_token

    def _headers(self, client_id: str, token: str) -> dict[str, str]:
        return {
            "Client-Id": client_id,
            "Authorization": f"Bearer {token}",
        }

    async def search_trending(
        self,
        client_id: str,
        client_secret: str,
        limit: int = 20,
    ) -> list[dict]:
        """Fetch top clips from currently trending games.

        Strategy: get top games, then fetch recent top clips from each.
        """
        try:
            token = await self._get_app_token(client_id, client_secret)
            headers = self._headers(client_id, token)

            # Step 1: Get top games.
            games_resp = await self._client.get(
                f"{TWITCH_HELIX_BASE}/games/top",
                headers=headers,
                params={"first": 10},
            )
            games_resp.raise_for_status()
            games = games_resp.json().get("data", [])

            if not games:
                return []

            # Step 2: Fetch top clips from each game (past 24 hours).
            started_at = (
                datetime.now(timezone.utc) - timedelta(hours=24)
            ).isoformat()
            clips_per_game = max(limit // len(games), 2)

            all_clips: list[TwitchClip] = []
            for game in games:
                game_id = game.get("id", "")
                game_name = game.get("name", "")
                if not game_id:
                    continue

                clips_resp = await self._client.get(
                    f"{TWITCH_HELIX_BASE}/clips",
                    headers=headers,
                    params={
                        "game_id": game_id,
                        "first": clips_per_game,
                        "started_at": started_at,
                    },
                )
                clips_resp.raise_for_status()

                for item in clips_resp.json().get("data", []):
                    all_clips.append(self._parse_clip(item, game_name))

            ranked = self._rank(all_clips)
            return [c.to_dict() for c in ranked[:limit]]

        except httpx.HTTPStatusError as exc:
            status = exc.response.status_code
            if status == 401:
                logger.error("Twitch auth failed — invalid client credentials")
                raise ValueError(
                    "Twitch API returned 401. Your Client ID or Secret may be "
                    "invalid. Check your .env file."
                ) from exc
            if status == 403:
                logger.error("Twitch API access forbidden")
                raise ValueError(
                    "Twitch API returned 403. Your app may not have the "
                    "required permissions."
                ) from exc
            logger.error("Twitch API error %s: %s", status, exc)
            raise ValueError(f"Twitch API error ({status}).") from exc
        except Exception as exc:
            logger.error("Twitch trending fetch failed: %s", exc)
            raise ValueError(f"Twitch trending failed: {exc}") from exc

    async def search_clips(
        self,
        client_id: str,
        client_secret: str,
        query: str,
        limit: int = 20,
    ) -> list[dict]:
        """Search for clips by game/category name.

        Strategy: search categories for the query, then fetch top clips
        from matching games.
        """
        try:
            token = await self._get_app_token(client_id, client_secret)
            headers = self._headers(client_id, token)

            # Step 1: Search for categories matching the query.
            cat_resp = await self._client.get(
                f"{TWITCH_HELIX_BASE}/search/categories",
                headers=headers,
                params={"query": query, "first": 5},
            )
            cat_resp.raise_for_status()
            categories = cat_resp.json().get("data", [])

            if not categories:
                return []

            # Step 2: Get clips from matched categories (past 7 days).
            started_at = (
                datetime.now(timezone.utc) - timedelta(days=7)
            ).isoformat()
            clips_per_cat = max(limit // len(categories), 3)

            all_clips: list[TwitchClip] = []
            for cat in categories:
                game_id = cat.get("id", "")
                game_name = cat.get("name", "")
                if not game_id:
                    continue

                clips_resp = await self._client.get(
                    f"{TWITCH_HELIX_BASE}/clips",
                    headers=headers,
                    params={
                        "game_id": game_id,
                        "first": clips_per_cat,
                        "started_at": started_at,
                    },
                )
                clips_resp.raise_for_status()

                for item in clips_resp.json().get("data", []):
                    all_clips.append(self._parse_clip(item, game_name))

            ranked = self._rank(all_clips)
            return [c.to_dict() for c in ranked[:limit]]

        except httpx.HTTPStatusError as exc:
            status = exc.response.status_code
            if status in (401, 403):
                raise ValueError(
                    f"Twitch API returned {status}. Check your Twitch "
                    "Client ID and Secret in .env."
                ) from exc
            logger.error("Twitch search API error %s: %s", status, exc)
            raise ValueError(f"Twitch API error ({status}).") from exc
        except Exception as exc:
            logger.error("Twitch clip search failed: %s", exc)
            raise ValueError(f"Twitch search failed: {exc}") from exc

    @staticmethod
    def _parse_clip(item: dict, game_name: str = "") -> TwitchClip:
        created_str = item.get("created_at", "")
        try:
            created = datetime.fromisoformat(
                created_str.replace("Z", "+00:00")
            )
        except (ValueError, AttributeError):
            created = datetime.now(timezone.utc)

        return TwitchClip(
            clip_id=item.get("id", ""),
            title=item.get("title", "Untitled Clip"),
            channel=item.get("broadcaster_name", "Unknown"),
            views=item.get("view_count", 0),
            likes=0,  # Twitch clips don't have likes
            comments=0,  # Twitch clips don't have comments
            created_at=created,
            thumbnail_url=item.get("thumbnail_url", ""),
            url=item.get("url", ""),
            game_name=game_name,
            duration=item.get("duration", 0.0),
        )

    def _rank(self, clips: list[TwitchClip]) -> list[TwitchClip]:
        now = datetime.now(timezone.utc)
        for c in clips:
            hours = max((now - c.created_at).total_seconds() / 3600, 1.0)
            c.velocity_score = c.views / hours
            # Twitch clips don't have likes/comments, so engagement is based
            # on view density alone.
            c.engagement_density = c.views / max(hours, 1)

        if not clips:
            return []

        max_vel = max(c.velocity_score for c in clips) or 1.0
        max_eng = max(c.engagement_density for c in clips) or 1.0

        for c in clips:
            c.composite_score = (
                self.VELOCITY_WEIGHT * (c.velocity_score / max_vel)
                + self.ENGAGEMENT_WEIGHT * (c.engagement_density / max_eng)
            )

        clips.sort(key=lambda c: c.composite_score, reverse=True)
        return clips

    # ─── Channel-first discovery ───

    async def search_channel(
        self, client_id: str, client_secret: str, username: str
    ) -> dict | None:
        """Look up a Twitch user by login name.

        Returns dict with: user_id, login, display_name, profile_image_url,
        description, view_count.
        """
        try:
            token = await self._get_app_token(client_id, client_secret)
            headers = self._headers(client_id, token)

            resp = await self._client.get(
                f"{TWITCH_HELIX_BASE}/users",
                headers=headers,
                params={"login": username.strip().lower()},
            )
            resp.raise_for_status()
            users = resp.json().get("data", [])
            if not users:
                return None

            u = users[0]
            return {
                "user_id": u.get("id", ""),
                "login": u.get("login", ""),
                "display_name": u.get("display_name", ""),
                "profile_image_url": u.get("profile_image_url", ""),
                "description": u.get("description", ""),
                "view_count": u.get("view_count", 0),
            }
        except httpx.HTTPStatusError as exc:
            raise ValueError(
                f"Twitch API error ({exc.response.status_code}) looking up user."
            ) from exc
        except Exception as exc:
            raise ValueError(f"Twitch user lookup failed: {exc}") from exc

    async def get_vods(
        self,
        client_id: str,
        client_secret: str,
        user_id: str,
        limit: int = 20,
    ) -> list[dict]:
        """Fetch recent archive VODs for a Twitch user.

        Uses /helix/videos?user_id=ID&type=archive.
        """
        try:
            token = await self._get_app_token(client_id, client_secret)
            headers = self._headers(client_id, token)

            resp = await self._client.get(
                f"{TWITCH_HELIX_BASE}/videos",
                headers=headers,
                params={
                    "user_id": user_id,
                    "type": "archive",
                    "first": min(limit, 100),
                },
            )
            resp.raise_for_status()

            vods = []
            for v in resp.json().get("data", []):
                vods.append({
                    "vod_id": v.get("id", ""),
                    "title": v.get("title", "Untitled"),
                    "url": v.get("url", ""),
                    "thumbnail_url": (
                        v.get("thumbnail_url", "")
                        .replace("%{width}", "320")
                        .replace("%{height}", "180")
                    ),
                    "duration": v.get("duration", "0h0m0s"),
                    "view_count": v.get("view_count", 0),
                    "created_at": v.get("created_at", ""),
                    "stream_id": v.get("stream_id", ""),
                })
            return vods

        except httpx.HTTPStatusError as exc:
            raise ValueError(
                f"Twitch API error ({exc.response.status_code}) fetching VODs."
            ) from exc
        except Exception as exc:
            raise ValueError(f"Twitch VOD fetch failed: {exc}") from exc

    async def get_clips_for_broadcaster(
        self,
        client_id: str,
        client_secret: str,
        broadcaster_id: str,
        vod_id: str | None = None,
        limit: int = 20,
    ) -> list[dict]:
        """Fetch clips for a broadcaster, optionally filtered to a specific VOD.

        If vod_id is provided, filters clips that have the matching video_id.
        Otherwise returns top recent clips for the broadcaster.
        """
        try:
            token = await self._get_app_token(client_id, client_secret)
            headers = self._headers(client_id, token)

            params: dict = {
                "broadcaster_id": broadcaster_id,
                "first": min(limit, 100),
            }

            resp = await self._client.get(
                f"{TWITCH_HELIX_BASE}/clips",
                headers=headers,
                params=params,
            )
            resp.raise_for_status()

            clips = []
            for item in resp.json().get("data", []):
                # If filtering by VOD, skip clips that don't match.
                if vod_id and item.get("video_id", "") != vod_id:
                    continue

                clips.append({
                    "clip_id": item.get("id", ""),
                    "title": item.get("title", ""),
                    "url": item.get("url", ""),
                    "embed_url": item.get("embed_url", ""),
                    "thumbnail_url": item.get("thumbnail_url", ""),
                    "view_count": item.get("view_count", 0),
                    "duration": item.get("duration", 0),
                    "created_at": item.get("created_at", ""),
                    "creator_name": item.get("creator_name", ""),
                    "video_id": item.get("video_id", ""),
                    "vod_offset": item.get("vod_offset", 0),
                    "broadcaster_name": item.get("broadcaster_name", ""),
                })

            clips.sort(key=lambda c: c.get("view_count", 0), reverse=True)
            return clips[:limit]

        except httpx.HTTPStatusError as exc:
            raise ValueError(
                f"Twitch API error ({exc.response.status_code}) fetching clips."
            ) from exc
        except Exception as exc:
            raise ValueError(f"Twitch clips fetch failed: {exc}") from exc

    async def close(self) -> None:
        await self._client.aclose()
