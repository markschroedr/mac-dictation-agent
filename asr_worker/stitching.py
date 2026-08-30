"""Text-only helpers for stitching overlapping streaming ASR chunks."""

from __future__ import annotations

import re
import string
from threading import Lock

_MIN_OVERLAP_CHARS = 12
_WORD_RE = re.compile(r"\w+", re.UNICODE)
_SEAM_PUNCTUATION = string.whitespace + string.punctuation + "…—–"

_session_lock = Lock()
_session_texts: dict[str, str] = {}


def commit_new_text(session_id: str, raw_text: str) -> str:
    """Return and remember only the portion of a session chunk not seen before."""
    if not raw_text:
        return ""
    with _session_lock:
        previous = _session_texts.get(session_id, "")
        text = remove_prefix_overlap(previous, raw_text)
        if text:
            separator = " " if previous.strip() else ""
            _session_texts[session_id] = f"{previous}{separator}{text}".strip()
        return text


def remove_prefix_overlap(previous: str, current: str) -> str:
    """Remove a word-aligned overlap between ``previous``'s end and ``current``'s start.

    Comparisons ignore case and punctuation, while the returned non-overlapping text
    retains its original spelling. As in the original implementation, overlaps must
    contain at least 12 characters to avoid treating short repeated phrases as
    chunk context.
    """
    previous = previous.strip()
    current = current.strip()
    if not previous or not current:
        return current

    previous_words = [
        (match.group().casefold(), match.start(), match.end())
        for match in _WORD_RE.finditer(previous)
    ]
    current_words = [
        (match.group().casefold(), match.start(), match.end())
        for match in _WORD_RE.finditer(current)
    ]

    max_words = min(len(previous_words), len(current_words))
    for count in range(max_words, 0, -1):
        previous_tokens = [word[0] for word in previous_words[-count:]]
        current_tokens = [word[0] for word in current_words[:count]]
        previous_span = previous_words[-1][2] - previous_words[-count][1]
        current_span = current_words[count - 1][2] - current_words[0][1]
        if min(previous_span, current_span) < _MIN_OVERLAP_CHARS:
            continue
        if previous_tokens == current_tokens:
            overlap_end = current_words[count - 1][2]
            return current[overlap_end:].lstrip(_SEAM_PUNCTUATION)
    return current


def reset_session_text(session_id: str) -> None:
    """Forget accumulated text for a completed or cancelled session."""
    with _session_lock:
        _session_texts.pop(session_id, None)
