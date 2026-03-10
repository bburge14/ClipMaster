"""Tests for the LLM Gateway service."""

from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, MagicMock

from clipmaster_sidecar.services.llm_gateway import (
    LlmGateway,
    LlmProvider,
    LlmRequest,
    LlmResponse,
)


def _loop():
    return asyncio.get_event_loop()


def test_llm_provider_values() -> None:
    assert LlmProvider.openai.value == "openai"
    assert LlmProvider.claude.value == "claude"
    assert LlmProvider.gemini.value == "gemini"


def test_llm_request_defaults() -> None:
    req = LlmRequest(provider=LlmProvider.openai, api_key="test-key", prompt="Hello")
    assert req.system_prompt == ""
    assert req.max_tokens == 2048
    assert req.temperature == 0.7


def test_llm_response_fields() -> None:
    resp = LlmResponse(text="Hello world", provider=LlmProvider.openai, model="gpt-4o", usage_tokens=42)
    assert resp.text == "Hello world"
    assert resp.provider == LlmProvider.openai
    assert resp.usage_tokens == 42


def test_generate_routes_to_openai() -> None:
    gateway = LlmGateway()
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.raise_for_status = MagicMock()
    mock_response.json.return_value = {
        "choices": [{"message": {"content": "AI response"}}],
        "model": "gpt-4o", "usage": {"total_tokens": 100},
    }
    gateway._client = MagicMock()
    gateway._client.post = AsyncMock(return_value=mock_response)

    result = _loop().run_until_complete(gateway.generate(
        LlmRequest(provider=LlmProvider.openai, api_key="test-key", prompt="Test prompt")
    ))
    assert result.text == "AI response"
    assert result.provider == LlmProvider.openai
    assert result.usage_tokens == 100


def test_generate_routes_to_claude() -> None:
    gateway = LlmGateway()
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.raise_for_status = MagicMock()
    mock_response.json.return_value = {
        "content": [{"type": "text", "text": "Claude response"}],
        "model": "claude-sonnet-4-20250514",
        "usage": {"input_tokens": 50, "output_tokens": 30},
    }
    gateway._client = MagicMock()
    gateway._client.post = AsyncMock(return_value=mock_response)

    result = _loop().run_until_complete(gateway.generate(
        LlmRequest(provider=LlmProvider.claude, api_key="test-key", prompt="Test prompt")
    ))
    assert result.text == "Claude response"
    assert result.provider == LlmProvider.claude
    assert result.usage_tokens == 80


def test_generate_routes_to_gemini() -> None:
    gateway = LlmGateway()
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.raise_for_status = MagicMock()
    mock_response.json.return_value = {
        "candidates": [{"content": {"parts": [{"text": "Gemini response"}]}}],
        "usageMetadata": {"totalTokenCount": 75},
    }
    gateway._client = MagicMock()
    gateway._client.post = AsyncMock(return_value=mock_response)

    result = _loop().run_until_complete(gateway.generate(
        LlmRequest(provider=LlmProvider.gemini, api_key="test-key", prompt="Test prompt")
    ))
    assert result.text == "Gemini response"
    assert result.provider == LlmProvider.gemini
    assert result.usage_tokens == 75


def test_claude_fallback_models() -> None:
    gateway = LlmGateway()
    call_count = 0

    async def mock_post(*args, **kwargs):
        nonlocal call_count
        call_count += 1
        resp = MagicMock()
        if call_count == 1:
            resp.status_code = 404
            resp.text = "Model not found"
            return resp
        resp.status_code = 200
        resp.json.return_value = {
            "content": [{"type": "text", "text": "Fallback worked"}],
            "model": "claude-3-5-sonnet-20241022",
            "usage": {"input_tokens": 10, "output_tokens": 20},
        }
        return resp

    gateway._client = MagicMock()
    gateway._client.post = mock_post

    result = _loop().run_until_complete(gateway.generate(
        LlmRequest(provider=LlmProvider.claude, api_key="test-key", prompt="Test prompt")
    ))
    assert result.text == "Fallback worked"
    assert call_count == 2


def test_gateway_configs() -> None:
    for provider in [LlmProvider.openai, LlmProvider.claude, LlmProvider.gemini]:
        assert provider in LlmGateway._CONFIGS
