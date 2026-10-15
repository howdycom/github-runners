"""Timestamps from the GitHub and Google Cloud APIs."""

from __future__ import annotations

from datetime import datetime


def parse_timestamp(value: str) -> float:
    """Seconds since the epoch for an RFC 3339 timestamp, with a Z or an offset."""
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
