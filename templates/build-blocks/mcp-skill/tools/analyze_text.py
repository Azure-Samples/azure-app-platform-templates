"""Deterministic structural text and Markdown analysis tool."""

from __future__ import annotations

import json
import re

from azure_functions_agents import tool

TOOL_NAME = "analyze_text"
TOOL_DESCRIPTION = (
    "Compute deterministic structural metrics (character, word, line, heading, "
    "question counts, and estimated token budget) for bounded UTF-8 text or markdown."
)
MAX_TEXT_LENGTH = 65_536
_UNSAFE_CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
_MARKDOWN_HEADING_RE = re.compile(r"^\s{0,3}#{1,6}(?:\s|$)", re.MULTILINE)


def compute_text_metrics(text: str) -> dict[str, int]:
    """Validate bounded UTF-8 input and return deterministic structural counts."""
    if not isinstance(text, str):
        raise ValueError("text must be a UTF-8 string.")
    if _UNSAFE_CONTROL_RE.search(text):
        raise ValueError("text must not contain NUL or control characters.")
    if not text or not text.strip():
        raise ValueError("text must be a non-empty string.")
    if len(text) > MAX_TEXT_LENGTH:
        raise ValueError(f"text must not exceed {MAX_TEXT_LENGTH} characters.")

    characters = len(text)
    words = len(text.split())
    lines = len(text.splitlines())
    markdown_headings = len(_MARKDOWN_HEADING_RE.findall(text))
    questions = text.count("?")
    estimated_tokens = max(1, (characters + 3) // 4)

    return {
        "characters": characters,
        "words": words,
        "lines": lines,
        "markdownHeadings": markdown_headings,
        "questions": questions,
        "estimatedTokens": estimated_tokens,
    }


@tool(name=TOOL_NAME, description=TOOL_DESCRIPTION)
def analyze_text(text: str) -> str:
    """Compute deterministic structural metrics for bounded UTF-8 text or markdown."""
    return json.dumps(compute_text_metrics(text))
