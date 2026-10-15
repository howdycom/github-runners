from __future__ import annotations

from ghr.timestamps import parse_timestamp


def test_parses_z_and_offset_timestamps() -> None:
    assert parse_timestamp("2027-01-15T08:00:00Z") == 1_800_000_000.0
    assert parse_timestamp("2027-01-15T00:00:00.000-08:00") == 1_800_000_000.0
