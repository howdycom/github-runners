"""Runs bake-image.sh against a stub gcloud that records its calls."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

BAKE = Path(__file__).resolve().parents[2] / "bake-image.sh"

GCLOUD_STUB = """#!/bin/bash
echo "gcloud $*" >> "$CALL_LOG"
case "$*" in
  *"instances describe"*) echo TERMINATED ;;
  *"get-serial-port-output"*) cat "$SERIAL_OUTPUT" ;;
esac
"""


def run_bake(tmp_path: Path, *args: str, serial: str = "ghr: bake complete\n") -> tuple[subprocess.CompletedProcess[str], list[str]]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    stub = bin_dir / "gcloud"
    stub.write_text(GCLOUD_STUB)
    stub.chmod(0o755)
    (tmp_path / "serial.txt").write_text(serial)
    call_log = tmp_path / "calls.log"
    env = {
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "CALL_LOG": str(call_log),
        "SERIAL_OUTPUT": str(tmp_path / "serial.txt"),
        "GHR_POLL_SECONDS": "0",
    }
    result = subprocess.run(["bash", str(BAKE), *args], env=env, capture_output=True, text=True, timeout=30)
    return result, call_log.read_text().splitlines()


def first(calls: list[str], fragment: str) -> str:
    return next(call for call in calls if fragment in call)


def test_bakes_in_a_temporary_network_and_removes_it(tmp_path: Path) -> None:
    result, calls = run_bake(tmp_path, "proj", "us-central1-a", "2.337.0", "f" * 64)

    assert result.returncode == 0, result.stdout + result.stderr
    create = first(calls, "instances create")
    builder = create.split()[4]  # gcloud compute instances create <name>
    assert f"--subnet={builder}" in create and "--no-address" not in create
    assert "runner-version=2.337.0,runner-sha256=" + "f" * 64 in create
    assert "--family=github-runner" in first(calls, "images create")
    # Cleanup deletes the builder, then its subnet and network.
    tail = [c.split()[1:4] for c in calls[-3:]]
    assert tail == [["compute", "instances", "delete"], ["compute", "networks", "subnets"], ["compute", "networks", "delete"]]
    assert first(calls, "networks create").split()[4] == builder


def test_uses_a_given_subnet_without_a_public_ip(tmp_path: Path) -> None:
    subnet = "projects/proj/regions/us-central1/subnetworks/ghr-subnet"
    result, calls = run_bake(tmp_path, "proj", "us-central1-a", "2.337.0", "f" * 64, subnet)

    assert result.returncode == 0, result.stdout + result.stderr
    create = first(calls, "instances create")
    assert f"--subnet={subnet}" in create and "--no-address" in create
    assert not any(" networks " in call for call in calls)


def test_creates_no_image_when_the_install_failed(tmp_path: Path) -> None:
    result, calls = run_bake(tmp_path, "proj", "us-central1-a", "2.337.0", "f" * 64, serial="ghr: failed at line 60\n")

    assert result.returncode == 1
    assert not any("images create" in call for call in calls)
    assert "instances delete" in calls[-3]


@pytest.mark.parametrize("args", [(), ("proj", "us-central1-a", "2.337.0")])
def test_prints_usage_without_enough_arguments(args: tuple[str, ...]) -> None:
    result = subprocess.run(["bash", str(BAKE), *args], capture_output=True, text=True, timeout=30)
    assert result.returncode == 1 and "Usage:" in result.stdout
