"""Fact Generator - AI-powered fact generation for short-form videos.

Uses the LLM Gateway to generate interesting facts per category.
The user picks a fact and the app creates a fact-based short from it.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass

from .llm_gateway import LlmGateway, LlmProvider, LlmRequest

logger = logging.getLogger("clipmaster_sidecar.fact_generator")

# Built-in prompts per category that produce short-form-video-friendly facts.
_CATEGORY_PROMPTS: dict[str, str] = {
    "space": (
        "Generate {count} fascinating and little-known facts about outer space, "
        "astronomy, planets, stars, black holes, or the universe. "
        "Each fact should be surprising, visually descriptive, and perfect for "
        "a 30-60 second short-form video narration."
    ),
    "history": (
        "Generate {count} fascinating and little-known historical facts about "
        "world events, ancient civilizations, famous figures, or turning points "
        "in history. Each fact should be dramatic, engaging, and perfect for "
        "a 30-60 second short-form video narration."
    ),
    "science": (
        "Generate {count} mind-blowing science facts about biology, chemistry, "
        "physics, or the natural world. Each fact should be surprising, easy to "
        "visualize, and perfect for a 30-60 second short-form video narration."
    ),
    "technology": (
        "Generate {count} surprising facts about technology, AI, computing, "
        "engineering, or inventions. Each fact should be fascinating, "
        "forward-looking, and perfect for a 30-60 second short-form video narration."
    ),
    "nature": (
        "Generate {count} incredible facts about nature, animals, ecosystems, "
        "oceans, or weather phenomena. Each fact should be visually rich, "
        "awe-inspiring, and perfect for a 30-60 second short-form video narration."
    ),
}

_SYSTEM_PROMPT = (
    "You are a fact researcher for a short-form video creator. "
    "Return ONLY a JSON array of objects, no markdown, no explanation. "
    "Each object must have:\n"
    '  - "title": a catchy 5-8 word title for the fact\n'
    '  - "fact": the full fact in 2-4 sentences, written as narration script\n'
    '  - "visual_keywords": array of 3-5 keywords for B-roll footage search\n'
    "\nExample:\n"
    '[{"title": "Saturn Could Float in Water", '
    '"fact": "Saturn is the least dense planet in our solar system. '
    "If you could find a bathtub big enough, Saturn would actually float in water. "
    "Its density is only 0.687 grams per cubic centimeter, lighter than water itself.\", "
    '"visual_keywords": ["saturn rings", "planet floating", "solar system", "water surface"]}]'
)


@dataclass
class GeneratedFact:
    title: str
    fact: str
    visual_keywords: list[str]

    def to_dict(self) -> dict:
        return {
            "title": self.title,
            "fact": self.fact,
            "visual_keywords": self.visual_keywords,
        }


class FactGenerator:
    """Generates facts via LLM for short-form video creation."""

    def __init__(self, llm_gateway: LlmGateway) -> None:
        self._llm = llm_gateway

    async def generate(
        self,
        category: str,
        count: int,
        provider: str,
        api_key: str,
    ) -> list[dict]:
        """Generate facts for a category using the specified LLM provider.

        Args:
            category: One of space, history, science, technology, nature.
            count: Number of facts to generate (1-10).
            provider: LLM provider name (openai, claude, gemini).
            api_key: The user's API key for that provider.

        Returns:
            List of fact dicts with title, fact, and visual_keywords.
        """
        category = category.lower()
        count = max(1, min(count, 10))

        prompt_template = _CATEGORY_PROMPTS.get(category)
        if not prompt_template:
            raise ValueError(f"Unknown category: {category}. Use: {list(_CATEGORY_PROMPTS.keys())}")

        prompt = prompt_template.format(count=count)

        logger.info("Generating %d %s facts via %s", count, category, provider)

        llm_response = await self._llm.generate(
            LlmRequest(
                provider=LlmProvider(provider),
                api_key=api_key,
                prompt=prompt,
                system_prompt=_SYSTEM_PROMPT,
                max_tokens=3000,
                temperature=0.8,
            )
        )

        facts = self._parse_response(llm_response.text)
        logger.info("Generated %d facts (tokens used: %d)", len(facts), llm_response.usage_tokens)
        return [f.to_dict() for f in facts]

    def _parse_response(self, text: str) -> list[GeneratedFact]:
        """Parse the LLM JSON response into GeneratedFact objects."""
        # Strip markdown code fences if the LLM wrapped it.
        cleaned = text.strip()
        cleaned = re.sub(r"^```(?:json)?\s*", "", cleaned)
        cleaned = re.sub(r"\s*```$", "", cleaned)

        try:
            data = json.loads(cleaned)
        except json.JSONDecodeError:
            logger.error("Failed to parse LLM response as JSON: %s", text[:200])
            # Try to extract JSON array from the response.
            match = re.search(r"\[.*\]", text, re.DOTALL)
            if match:
                data = json.loads(match.group())
            else:
                raise ValueError("LLM did not return valid JSON. Try again.")

        if not isinstance(data, list):
            data = [data]

        facts = []
        for item in data:
            facts.append(
                GeneratedFact(
                    title=item.get("title", "Untitled Fact"),
                    fact=item.get("fact", ""),
                    visual_keywords=item.get("visual_keywords", []),
                )
            )
        return facts
