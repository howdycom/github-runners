"""Runs bake-image.sh against a stub gcloud that records its calls.

The stub behaves like Compute Engine where it matters: the builder reports
RUNNING for a few polls and then TERMINATED, and its serial console can only
be read while it runs.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

BAKE = Path(__file__).resolve().parents[2] / "bake-image.sh"
SHA = "f" * 64

GCLOUD_STUB = r"""#!/bin/bash
echo "gcloud $*" >> "$CALL_LOG"
case "$*" in
  *"instances create"*)
    [ -n "$FAIL_CREATE" ] && { echo "ZONE_RESOURCE_POOL_EXHAUSTED" >&2; exit 1; }
    ;;
  *"instances delete"*)
    [ -n "$FAIL_DELETE" ] && exit 1
    ;;
  *"instances describe"*)
    polls=$(( $(cat "$POLLS" 2>/dev/null || echo 0) + 1 ))
    echo "$polls" > "$POLLS"
    if [ "$polls" -le "$RUNNING_POLLS" ]; then echo RUNNING; else echo TERMINATED; fi
    ;;
  *"get-serial-port-output"*)
    polls=$(cat "$POLLS" 2>/dev/null || echo 0)
    if [ "$polls" -gt "$RUNNING_POLLS" ]; then
      echo "ERROR: The resource is not ready" >&2
      exit 1
    fi
    cat "$SERIAL_OUTPUT"
    ;;
esac
exit 0
"""


def run_bake(
    tmp_path: Path,
    *args: str,
    serial: str = "ghr: bake complete\n",
    running_polls: int = 2,
    fail_create: bool = False,
    fail_delete: bool = False,
) -> tuple[subprocess.CompletedProcess[str], list[str]]:
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
        "POLLS": str(tmp_path / "polls"),
        "RUNNING_POLLS": str(running_polls),
        "FAIL_CREATE": "1" if fail_create else "",
        "FAIL_DELETE": "1" if fail_delete else "",
        "GHR_POLL_SECONDS": "0",
    }
    result = subprocess.run(["bash", str(BAKE), *args], env=env, capture_output=True, text=True, timeout=60)
    return result, call_log.read_text().splitlines()


def first(calls: list[str], fragment: str) -> str:
    return next(call for call in calls if fragment in call)


def test_bakes_in_a_temporary_network_and_removes_it(tmp_path: Path) -> None:
    result, calls = run_bake(tmp_path, "proj", "us-central1-a", "2.337.0", SHA)

    assert result.returncode == 0, result.stdout + result.stderr
    create = first(calls, "instances create")
    builder = create.split()[4]  # gcloud compute instances create <name>
    assert f"--subnet={builder}" in create and "--no-address" not in create
    assert f"runner-version=2.337.0,runner-sha256={SHA}" in create
    assert "--machine-type=e2-standard-2" in create
    assert "--family=github-runner" in first(calls, "images create")
    # Cleanup deletes the builder, then its subnet and network.
    tail = [c.split()[1:4] for c in calls[-3:]]
    assert tail == [["compute", "instances", "delete"], ["compute", "networks", "subnets"], ["compute", "networks", "delete"]]
    assert first(calls, "networks create").split()[4] == builder


def test_reads_the_console_while_the_builder_runs(tmp_path: Path) -> None:
    # Compute Engine returns no serial output for a stopped VM, so the marker
    # has to be seen before the builder stops.
    result, calls = run_bake(tmp_path, "proj", "us-central1-a", "2.337.0", SHA, running_polls=1)

    assert result.returncode == 0, result.stdout + result.stderr
    assert any("images create" in call for call in calls)


def test_uses_a_given_subnet_without_a_public_ip(tmp_path: Path) -> None:
    subnet = "projects/proj/regions/us-central1/subnetworks/ghr-subnet"
    result, calls = run_bake(tmp_path, "proj", "us-central1-a", "2.337.0", SHA, subnet)

    assert result.returncode == 0, result.stdout + result.stderr
    create = first(calls, "instances create")
    assert f"--subnet={subnet}" in create and "--no-address" in create
    assert not any(" networks " in call for call in calls)


def test_creates_no_image_when_the_install_failed(tmp_path: Path) -> None:
    result, calls = run_bake(tmp_path, "proj", "us-central1-a", "2.337.0", SHA, serial="ghr: failed at line 60\n")

    assert result.returncode == 1
    assert not any("images create" in call for call in calls)
    assert "ghr: failed at line 60" in result.stdout  # the end of the console is printed
    assert "instances delete" in calls[-3]


def test_creates_no_image_when_the_builder_never_ran(tmp_path: Path) -> None:
    result, calls = run_bake(tmp_path, "proj", "us-central1-a", "2.337.0", SHA, running_polls=0)

    assert result.returncode == 1
    assert not any("images create" in call for call in calls)


def test_finds_the_marker_in_a_large_serial_log(tmp_path: Path) -> None:
    # A real builder's serial log is megabytes long. grep -q stops reading at the
    # marker, so a pipe from gcloud into it fails with SIGPIPE under pipefail.
    serial = "ghr: bake complete\n" + "apt output line\n" * 400_000
    result, calls = run_bake(tmp_path, "proj", "us-central1-a", "2.337.0", SHA, serial=serial)

    assert result.returncode == 0, result.stdout + result.stderr
    assert any("images create" in call for call in calls)


def test_a_failed_create_removes_the_network_and_no_builder(tmp_path: Path) -> None:
    result, calls = run_bake(tmp_path, "proj", "us-central1-a", "2.337.0", SHA, fail_create=True)

    assert result.returncode != 0
    assert not any("instances delete" in call for call in calls)
    assert any("networks delete" in call for call in calls)
    assert "WARNING" not in result.stdout


def test_reports_a_builder_it_could_not_remove(tmp_path: Path) -> None:
    result, _ = run_bake(tmp_path, "proj", "us-central1-a", "2.337.0", SHA, fail_delete=True)

    assert "WARNING: could not remove a builder resource" in result.stdout
    assert "gcloud compute instances delete github-runner-bake-" in result.stdout


@pytest.mark.parametrize("args", [(), ("proj", "us-central1-a", "2.337.0")])
def test_prints_usage_without_enough_arguments(args: tuple[str, ...]) -> None:
    result = subprocess.run(["bash", str(BAKE), *args], capture_output=True, text=True, timeout=30)
    assert result.returncode == 1 and "Usage:" in result.stdout
