"""Tests for the Fact-Shorts Script Analyzer."""

from __future__ import annotations

from clipmaster_sidecar.services.script_analyzer import ScriptAnalyzer


def test_empty_script_returns_empty() -> None:
    analyzer = ScriptAnalyzer()
    result = analyzer.analyze("")
    assert result == {}


def test_whitespace_script_returns_empty() -> None:
    analyzer = ScriptAnalyzer()
    result = analyzer.analyze("   \n  \t  ")
    assert result == {}


def test_basic_script_produces_timestamps() -> None:
    script = (
        "Deep in the ocean lies a mysterious trench that scientists have never fully explored. "
        "The Mariana Trench plunges nearly seven miles below the surface of the Pacific. "
        "At those depths the pressure is crushing and the darkness is absolute. "
        "Yet even here bizarre creatures thrive around volcanic vents on the ocean floor. "
        "Glowing jellyfish and eyeless shrimp navigate this alien world with ease. "
        "Some scientists believe these extreme environments mirror conditions on distant moons. "
        "Europa the icy moon of Jupiter may hide a vast ocean beneath its frozen crust. "
        "If life can survive in Earth deepest trenches it could exist on Europa too. "
        "Future missions aim to send robotic submarines through the ice to search for signs of life."
    )
    analyzer = ScriptAnalyzer()
    result = analyzer.analyze(script, block_duration_seconds=5)

    # Should produce multiple timestamp entries.
    assert len(result) > 0

    # All keys should be valid MM:SS format.
    for key in result:
        parts = key.split(":")
        assert len(parts) == 2
        assert parts[0].isdigit()
        assert parts[1].isdigit()

    # First entry should start at 00:00.
    assert "00:00" in result

    # Values should be non-empty strings (the visual keywords).
    for value in result.values():
        assert isinstance(value, str)
        assert len(value) > 0


def test_visual_domain_words_rank_higher() -> None:
    """Words in the visual domain (e.g., 'nebula', 'galaxy') should appear."""
    script = (
        "A supernova explodes sending shockwaves across the galaxy. "
        "The resulting nebula glows with brilliant colors for thousands of years. "
        "Stars are born from these clouds of cosmic dust and gas."
    )
    analyzer = ScriptAnalyzer()
    result = analyzer.analyze(script, block_duration_seconds=5)

    # At least one keyword should reference a visual domain word.
    all_keywords = " ".join(result.values()).lower()
    visual_words_found = any(
        w in all_keywords for w in ["nebula", "galaxy", "supernova", "star"]
    )
    assert visual_words_found, f"Expected visual keywords in: {all_keywords}"


def test_block_duration_affects_count() -> None:
    """Shorter blocks should produce more timestamp entries."""
    script = "The ancient pyramid stands tall against the desert sunset. " * 10
    analyzer = ScriptAnalyzer()

    result_5s = analyzer.analyze(script, block_duration_seconds=5)
    result_10s = analyzer.analyze(script, block_duration_seconds=10)

    assert len(result_5s) >= len(result_10s)


def test_output_format_matches_spec() -> None:
    """Verify the output matches the spec: {"00:05": "cinematic nebula", ...}"""
    script = (
        "The telescope reveals distant galaxies billions of light years away. "
        "Each galaxy contains hundreds of billions of stars. "
        "Black holes lurk at the center of most galaxies pulling in everything nearby."
    )
    analyzer = ScriptAnalyzer()
    result = analyzer.analyze(script, block_duration_seconds=5)

    assert isinstance(result, dict)
    for key, value in result.items():
        # Key format: "MM:SS"
        assert isinstance(key, str)
        assert len(key) == 5
        assert key[2] == ":"
        # Value: a descriptive keyword string
        assert isinstance(value, str)
        assert len(value.split()) >= 2  # modifier + keyword
