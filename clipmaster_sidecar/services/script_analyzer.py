"""Fact-Shorts Script Analyzer.

Takes a narrated script and returns a JSON mapping of timestamps
to visual search keywords for B-roll auto-assembly.

Example output:
    {
        "00:00": "deep ocean underwater",
        "00:05": "cinematic nebula",
        "00:10": "spinning galaxy",
        "00:15": "astronaut floating space"
    }
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass

logger = logging.getLogger("clipmaster_sidecar.script_analyzer")

# Words that are too generic to be useful as visual search keywords.
_STOP_WORDS = frozenset(
    {
        "the",
        "a",
        "an",
        "is",
        "are",
        "was",
        "were",
        "be",
        "been",
        "being",
        "have",
        "has",
        "had",
        "do",
        "does",
        "did",
        "will",
        "would",
        "could",
        "should",
        "may",
        "might",
        "shall",
        "can",
        "it",
        "its",
        "this",
        "that",
        "these",
        "those",
        "i",
        "you",
        "he",
        "she",
        "we",
        "they",
        "me",
        "him",
        "her",
        "us",
        "them",
        "my",
        "your",
        "his",
        "our",
        "their",
        "what",
        "which",
        "who",
        "whom",
        "when",
        "where",
        "why",
        "how",
        "not",
        "no",
        "nor",
        "but",
        "and",
        "or",
        "if",
        "then",
        "so",
        "than",
        "too",
        "very",
        "just",
        "about",
        "above",
        "after",
        "again",
        "all",
        "also",
        "any",
        "because",
        "before",
        "between",
        "both",
        "by",
        "each",
        "for",
        "from",
        "get",
        "got",
        "in",
        "into",
        "of",
        "on",
        "once",
        "only",
        "other",
        "over",
        "own",
        "same",
        "some",
        "such",
        "to",
        "under",
        "until",
        "up",
        "with",
        "there",
        "here",
        "one",
        "two",
        "three",
        "much",
        "many",
        "more",
        "most",
        "well",
        "even",
        "still",
        "ever",
        "make",
        "like",
        "think",
        "know",
        "take",
        "come",
        "go",
        "see",
        "look",
    }
)

# Cinematic style modifiers to prepend for better stock footage results.
_CINEMATIC_MODIFIERS = [
    "cinematic",
    "dramatic",
    "aerial view",
    "close-up",
    "slow motion",
    "time-lapse",
]


@dataclass
class VisualKeyword:
    """A keyword extracted from a script block with a relevance score."""

    word: str
    score: float  # 0.0 - 1.0 relevance


class ScriptAnalyzer:
    """Analyzes a narration script and maps timestamps to visual keywords.

    The algorithm:
        1. Split the script into time blocks (default 5 seconds each).
        2. For each block, extract nouns/adjectives by filtering stop words
           and scoring remaining words by specificity (length, capitalization).
        3. Combine top keywords with a cinematic modifier for better
           stock footage search results.

    For production use, this would call the user's LLM (via BYOK keys) for
    more intelligent keyword extraction. This local implementation provides
    a functional baseline without any API dependency.
    """

    # Average speaking rate: ~2.5 words/second for narration.
    WORDS_PER_SECOND = 2.5

    def analyze(
        self,
        script: str,
        block_duration_seconds: int = 5,
    ) -> dict[str, str]:
        """Analyze a script and return timestamp -> keyword mapping.

        Args:
            script: The full narration text.
            block_duration_seconds: Duration of each visual block.

        Returns:
            Dict mapping "MM:SS" timestamps to visual search keyword strings.
            Example: {"00:00": "cinematic nebula", "00:05": "spinning galaxy"}
        """
        if not script.strip():
            return {}

        words = script.split()
        words_per_block = int(self.WORDS_PER_SECOND * block_duration_seconds)
        blocks = self._chunk(words, words_per_block)

        visual_map: dict[str, str] = {}
        for i, block in enumerate(blocks):
            timestamp = self._format_timestamp(i * block_duration_seconds)
            keywords = self._extract_keywords(block)
            if keywords:
                # Pick the top keyword and prepend a cinematic modifier.
                top = keywords[0]
                modifier = _CINEMATIC_MODIFIERS[i % len(_CINEMATIC_MODIFIERS)]
                visual_map[timestamp] = f"{modifier} {top.word}"
            else:
                visual_map[timestamp] = "abstract motion background"

        logger.info("Analyzed script into %d visual blocks.", len(visual_map))
        return visual_map

    def _extract_keywords(self, words: list[str]) -> list[VisualKeyword]:
        """Extract and rank visual keywords from a block of words."""
        candidates: list[VisualKeyword] = []

        for raw_word in words:
            clean = re.sub(r"[^a-zA-Z]", "", raw_word).lower()
            if not clean or clean in _STOP_WORDS or len(clean) < 3:
                continue

            score = self._score_word(raw_word, clean)
            candidates.append(VisualKeyword(word=clean, score=score))

        # Deduplicate and sort by score descending.
        seen: set[str] = set()
        unique: list[VisualKeyword] = []
        for kw in sorted(candidates, key=lambda k: k.score, reverse=True):
            if kw.word not in seen:
                seen.add(kw.word)
                unique.append(kw)

        return unique[:3]  # Return top 3 keywords per block.

    def _score_word(self, raw: str, clean: str) -> float:
        """Score a word's relevance as a visual keyword.

        Heuristics:
            - Longer words are typically more specific/visual (0.0 - 0.4).
            - Capitalized words may be proper nouns / named entities (0.3).
            - Words with strong visual connotation get a bonus (0.3).
        """
        score = 0.0

        # Length bonus: longer = more specific.
        score += min(len(clean) / 20.0, 0.4)

        # Capitalization bonus: proper nouns are often searchable entities.
        if raw[0].isupper() and not raw.isupper():
            score += 0.3

        # Visual domain bonus: words commonly associated with footage.
        visual_domains = {
            "ocean", "mountain", "city", "forest", "sky", "sun", "moon",
            "star", "planet", "earth", "fire", "water", "storm", "light",
            "dark", "night", "space", "galaxy", "nebula", "explosion",
            "animal", "bird", "fish", "whale", "desert", "snow", "ice",
            "volcano", "river", "lake", "cloud", "rain", "lightning",
            "sunset", "sunrise", "crystal", "diamond", "gold", "ancient",
            "ruins", "temple", "pyramid", "castle", "rocket", "satellite",
            "telescope", "microscope", "cell", "dna", "brain", "heart",
            "supernova", "asteroid", "comet", "aurora", "coral", "reef",
        }
        if clean in visual_domains:
            score += 0.3

        return score

    @staticmethod
    def _chunk(lst: list[str], size: int) -> list[list[str]]:
        """Split a list into chunks of the given size."""
        return [lst[i : i + size] for i in range(0, len(lst), size)] if size > 0 else [lst]

    @staticmethod
    def _format_timestamp(seconds: int) -> str:
        """Format seconds as MM:SS."""
        mins, secs = divmod(seconds, 60)
        return f"{mins:02d}:{secs:02d}"
