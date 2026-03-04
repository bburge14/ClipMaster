"""Multi-provider LLM Gateway.

Routes requests to the user's configured LLM providers (Gemini, Claude, OpenAI)
with round-robin key selection. Keys are passed from the Flutter side per request
(they're stored in Windows Credential Manager on the Flutter side).
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from enum import Enum

import httpx

logger = logging.getLogger("clipmaster_sidecar.llm_gateway")


class LlmProvider(str, Enum):
    gemini = "gemini"
    claude = "claude"
    openai = "openai"


@dataclass
class LlmRequest:
    provider: LlmProvider
    api_key: str
    prompt: str
    system_prompt: str = ""
    max_tokens: int = 2048
    temperature: float = 0.7


@dataclass
class LlmResponse:
    text: str
    provider: LlmProvider
    model: str
    usage_tokens: int


class LlmGateway:
    """Unified gateway for multiple LLM providers."""

    # Provider-specific endpoints and model defaults.
    _CONFIGS = {
        LlmProvider.openai: {
            "url": "https://api.openai.com/v1/chat/completions",
            "model": "gpt-4o",
        },
        LlmProvider.claude: {
            "url": "https://api.anthropic.com/v1/messages",
            "model": "claude-sonnet-4-20250514",
        },
        LlmProvider.gemini: {
            "url": "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
            "model": "gemini-2.0-flash",
        },
    }

    def __init__(self) -> None:
        self._client = httpx.AsyncClient(timeout=60.0)

    async def generate(self, request: LlmRequest) -> LlmResponse:
        """Send a prompt to the specified provider and return the response."""
        match request.provider:
            case LlmProvider.openai:
                return await self._call_openai(request)
            case LlmProvider.claude:
                return await self._call_claude(request)
            case LlmProvider.gemini:
                return await self._call_gemini(request)

    async def _call_openai(self, req: LlmRequest) -> LlmResponse:
        config = self._CONFIGS[LlmProvider.openai]
        messages = []
        if req.system_prompt:
            messages.append({"role": "system", "content": req.system_prompt})
        messages.append({"role": "user", "content": req.prompt})

        resp = await self._client.post(
            config["url"],
            headers={"Authorization": f"Bearer {req.api_key}"},
            json={
                "model": config["model"],
                "messages": messages,
                "max_tokens": req.max_tokens,
                "temperature": req.temperature,
            },
        )
        resp.raise_for_status()
        data = resp.json()

        return LlmResponse(
            text=data["choices"][0]["message"]["content"],
            provider=LlmProvider.openai,
            model=data.get("model", config["model"]),
            usage_tokens=data.get("usage", {}).get("total_tokens", 0),
        )

    async def _call_claude(self, req: LlmRequest) -> LlmResponse:
        config = self._CONFIGS[LlmProvider.claude]

        resp = await self._client.post(
            config["url"],
            headers={
                "x-api-key": req.api_key,
                "anthropic-version": "2025-04-01",
                "content-type": "application/json",
            },
            json={
                "model": config["model"],
                "max_tokens": req.max_tokens,
                "system": req.system_prompt or "You are a helpful assistant.",
                "messages": [{"role": "user", "content": req.prompt}],
            },
        )
        resp.raise_for_status()
        data = resp.json()

        text = ""
        for block in data.get("content", []):
            if block.get("type") == "text":
                text += block.get("text", "")

        return LlmResponse(
            text=text,
            provider=LlmProvider.claude,
            model=data.get("model", config["model"]),
            usage_tokens=data.get("usage", {}).get("input_tokens", 0)
            + data.get("usage", {}).get("output_tokens", 0),
        )

    async def _call_gemini(self, req: LlmRequest) -> LlmResponse:
        config = self._CONFIGS[LlmProvider.gemini]
        url = config["url"].format(model=config["model"])

        resp = await self._client.post(
            url,
            params={"key": req.api_key},
            json={
                "contents": [{"parts": [{"text": req.prompt}]}],
                "generationConfig": {
                    "maxOutputTokens": req.max_tokens,
                    "temperature": req.temperature,
                },
            },
        )
        resp.raise_for_status()
        data = resp.json()

        text = ""
        candidates = data.get("candidates", [])
        if candidates:
            parts = candidates[0].get("content", {}).get("parts", [])
            text = "".join(p.get("text", "") for p in parts)

        return LlmResponse(
            text=text,
            provider=LlmProvider.gemini,
            model=config["model"],
            usage_tokens=data.get("usageMetadata", {}).get("totalTokenCount", 0),
        )

    async def close(self) -> None:
        await self._client.aclose()
