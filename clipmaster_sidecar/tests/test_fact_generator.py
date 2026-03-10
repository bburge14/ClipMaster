"""Tests for the Fact Generator service."""

from __future__ import annotations

import asyncio
import json
from unittest.mock import AsyncMock, MagicMock

import pytest

from clipmaster_sidecar.services.fact_generator import FactGenerator, GeneratedFact
from clipmaster_sidecar.services.llm_gateway import LlmGateway, LlmProvider, LlmResponse


def _make_generator() -> tuple[FactGenerator, MagicMock]:
    gateway = MagicMock(spec=LlmGateway)
    return FactGenerator(gateway), gateway


def test_generated_fact_to_dict() -> None:
    fact = GeneratedFact(
        title="Saturn Could Float",
        fact="Saturn is the least dense planet.",
        visual_keywords=["saturn", "planet", "water"],
    )
    d = fact.to_dict()
    assert d["title"] == "Saturn Could Float"
    assert d["fact"] == "Saturn is the least dense planet."
    assert d["visual_keywords"] == ["saturn", "planet", "water"]


def test_generate_returns_parsed_facts() -> None:
    gen, gateway = _make_generator()
    response_json = json.dumps([
        {"title": "Fact One", "fact": "This is fact one.", "visual_keywords": ["keyword1"]},
        {"title": "Fact Two", "fact": "This is fact two.", "visual_keywords": ["keyword3"]},
    ])
    gateway.generate = AsyncMock(return_value=LlmResponse(
        text=response_json, provider=LlmProvider.openai, model="gpt-4o", usage_tokens=100,
    ))

    facts = asyncio.get_event_loop().run_until_complete(
        gen.generate(category="science", count=2, provider="openai", api_key="test-key")
    )
    assert len(facts) == 2
    assert facts[0]["title"] == "Fact One"
    assert facts[1]["title"] == "Fact Two"


def test_generate_handles_markdown_wrapped_json() -> None:
    gen, gateway = _make_generator()
    response_text = '```json\n[{"title": "Wrapped", "fact": "In markdown.", "visual_keywords": ["test"]}]\n```'
    gateway.generate = AsyncMock(return_value=LlmResponse(
        text=response_text, provider=LlmProvider.openai, model="gpt-4o", usage_tokens=50,
    ))

    facts = asyncio.get_event_loop().run_until_complete(
        gen.generate(category="space", count=1, provider="openai", api_key="test-key")
    )
    assert len(facts) == 1
    assert facts[0]["title"] == "Wrapped"


def test_generate_clamps_count() -> None:
    gen, gateway = _make_generator()
    gateway.generate = AsyncMock(return_value=LlmResponse(
        text='[{"title": "T", "fact": "F", "visual_keywords": []}]',
        provider=LlmProvider.openai, model="gpt-4o", usage_tokens=10,
    ))

    loop = asyncio.get_event_loop()
    loop.run_until_complete(gen.generate(category="science", count=0, provider="openai", api_key="k"))
    loop.run_until_complete(gen.generate(category="science", count=50, provider="openai", api_key="k"))
    assert gateway.generate.call_count == 2


def test_generate_unknown_category_raises() -> None:
    gen, _ = _make_generator()
    with pytest.raises(ValueError, match="Unknown category"):
        asyncio.get_event_loop().run_until_complete(
            gen.generate(category="bogus", count=1, provider="openai", api_key="test")
        )


def test_generate_custom_prompt() -> None:
    gen, gateway = _make_generator()
    gateway.generate = AsyncMock(return_value=LlmResponse(
        text='[{"title": "Custom", "fact": "Custom fact.", "visual_keywords": ["c"]}]',
        provider=LlmProvider.openai, model="gpt-4o", usage_tokens=30,
    ))

    facts = asyncio.get_event_loop().run_until_complete(
        gen.generate(category="science", count=1, provider="openai", api_key="k",
                     custom_prompt="Tell me about dogs")
    )
    assert len(facts) == 1
    assert facts[0]["title"] == "Custom"
    call_args = gateway.generate.call_args[0][0]
    assert "dogs" in call_args.prompt


def test_parse_response_handles_non_array() -> None:
    gen = FactGenerator(MagicMock())
    facts = gen._parse_response('{"title": "Single", "fact": "F", "visual_keywords": []}')
    assert len(facts) == 1
    assert facts[0].title == "Single"


def test_parse_response_extracts_json_from_text() -> None:
    gen = FactGenerator(MagicMock())
    text = 'Here are some facts: [{"title": "Embedded", "fact": "F", "visual_keywords": []}] Hope this helps!'
    facts = gen._parse_response(text)
    assert len(facts) == 1
    assert facts[0].title == "Embedded"
