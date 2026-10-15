"""Runs runner/startup.sh with stub commands instead of a real VM.

curl serves instance metadata from a directory, and systemctl, apt-get and
runuser only record their calls. No root, network or Docker is needed.
"""

from __future__ import annotations

import hashlib
import io
import os
import subprocess
import tarfile
from dataclasses import dataclass
from pathlib import Path

import pytest

STARTUP = Path(__file__).resolve().parents[1] / "startup.sh"

CURL_STUB = r"""#!/bin/bash
# Serves metadata from $FAKE_METADATA and downloads from $FAKE_DOWNLOADS.
echo "curl $*" >> "$CALL_LOG"
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -H) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  http://metadata.google.internal/*)
    file="$FAKE_METADATA/${url##*/}"
    [ -f "$file" ] || exit 22
    cat "$file"
    ;;
  *)
    file="$FAKE_DOWNLOADS/${url##*/}"
    [ -f "$file" ] || exit 22
    if [ -n "$out" ]; then cp "$file" "$out"; else cat "$file"; fi
    ;;
esac
"""

RECORDING_STUB = """#!/bin/bash
echo "$(basename "$0") $*" >> "$CALL_LOG"
"""

# runuser -u <user> -- <command...>: run the command as the current user.
RUNUSER_STUB = """#!/bin/bash
echo "runuser $*" >> "$CALL_LOG"
shift 3
exec "$@"
"""


@dataclass
class Harness:
    root: Path
    metadata: Path
    downloads: Path
    runner_dir: Path
    marker: Path
    call_log: Path

    def set_metadata(self, key: str, value: str) -> None:
        (self.metadata / key).write_text(value)

    def run(self, timeout: float = 30) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", str(STARTUP)], env=self.env(), capture_output=True, text=True, timeout=timeout)

    def call_function(self, command: str, timeout: float = 30) -> subprocess.CompletedProcess[str]:
        """Sources startup.sh without running it, then runs one shell command."""
        env = {**self.env(), "GHR_SOURCE_ONLY": "1"}
        script = f'source "{STARTUP}"; {command}'
        return subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True, timeout=timeout)

    def env(self) -> dict[str, str]:
        return {
            "PATH": f"{self.root / 'bin'}:{os.environ['PATH']}",
            "CALL_LOG": str(self.call_log),
            "FAKE_METADATA": str(self.metadata),
            "FAKE_DOWNLOADS": str(self.downloads),
            "GHR_RUNNER_DIR": str(self.runner_dir),
            "GHR_INSTALLED_MARKER": str(self.marker),
        }

    def calls(self) -> list[str]:
        return self.call_log.read_text().splitlines() if self.call_log.exists() else []


@pytest.fixture
def harness(tmp_path: Path) -> Harness:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    stubs = {"curl": CURL_STUB, "runuser": RUNUSER_STUB}
    for name in ("systemctl", "apt-get", "chown"):
        stubs[name] = RECORDING_STUB
    for name, body in stubs.items():
        stub = bin_dir / name
        stub.write_text(body)
        stub.chmod(0o755)
    for directory in ("metadata", "downloads", "runner"):
        (tmp_path / directory).mkdir()
    return Harness(
        root=tmp_path,
        metadata=tmp_path / "metadata",
        downloads=tmp_path / "downloads",
        runner_dir=tmp_path / "runner",
        marker=tmp_path / "installed",
        call_log=tmp_path / "calls.log",
    )


def test_powers_off_without_a_jit_config(harness: Harness) -> None:
    result = harness.run()
    assert result.returncode == 0
    assert "ghr: no jit-config in metadata" in result.stdout
    assert "systemctl poweroff" in harness.calls()


def test_a_failed_metadata_read_in_a_substitution_stops_the_install(harness: Harness) -> None:
    # No runner-version in metadata: the install must stop before apt-get,
    # instead of carrying the trap's log text on as the version.
    harness.set_metadata("jit-config", "config")
    result = harness.run()

    assert "ghr: failed at line" in result.stdout
    assert "systemctl poweroff" in harness.calls()
    assert not any(call.startswith("apt-get") for call in harness.calls())
    assert not harness.marker.exists()


def fake_runner_tarball() -> tuple[bytes, str]:
    """A tarball shaped like the runner release, and its SHA-256."""
    script = b"#!/bin/bash\ntouch \"$(dirname \"$0\")/../dependencies-installed\"\n"
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        info = tarfile.TarInfo("bin/installdependencies.sh")
        info.size = len(script)
        info.mode = 0o755
        archive.addfile(info, io.BytesIO(script))
    data = buffer.getvalue()
    return data, hashlib.sha256(data).hexdigest()


def test_installs_the_runner_when_the_checksum_matches(harness: Harness) -> None:
    data, sha256 = fake_runner_tarball()
    (harness.downloads / "actions-runner-linux-x64-2.337.0.tar.gz").write_bytes(data)

    result = harness.call_function(f"install_runner 2.337.0 {sha256}")

    assert result.returncode == 0, result.stdout + result.stderr
    assert (harness.runner_dir / "dependencies-installed").exists()
    assert not any("api.github.com" in call for call in harness.calls())


def test_refuses_a_runner_whose_checksum_does_not_match(harness: Harness) -> None:
    data, _ = fake_runner_tarball()
    (harness.downloads / "actions-runner-linux-x64-2.337.0.tar.gz").write_bytes(data)

    result = harness.call_function(f"install_runner 2.337.0 {'0' * 64}")

    assert "ghr: failed at line" in result.stdout
    assert "systemctl poweroff" in harness.calls()
    assert not (harness.runner_dir / "dependencies-installed").exists()
