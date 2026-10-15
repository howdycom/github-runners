"""Structured logs. Cloud Logging parses one JSON object per stdout line."""

from __future__ import annotations

import json
import sys
from typing import Any


def _emit(severity: str, message: str, fields: dict[str, Any]) -> None:
    print(json.dumps({"severity": severity, "message": message, **fields}, default=str), file=sys.stdout, flush=True)


def info(message: str, **fields: Any) -> None:
    _emit("INFO", message, fields)


def warning(message: str, **fields: Any) -> None:
    _emit("WARNING", message, fields)


def error(message: str, **fields: Any) -> None:
    _emit("ERROR", message, fields)
