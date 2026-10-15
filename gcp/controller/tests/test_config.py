from __future__ import annotations

import pytest

from ghr.config import Config

ENV = {
    "GCP_PROJECT": "p",
    "ZONES": "zone-a, zone-b,,",
    "INSTANCE_TEMPLATE": "projects/p/global/instanceTemplates/t",
    "NAME_PREFIX": "ghr",
    "RUNNER_LABEL": "GCP-X64",
    "RUNNER_GROUP": "gcp-runners",
    "GITHUB_ORG": "example-org",
    "GITHUB_APP_ID": "1",
    "GITHUB_INSTALLATION_ID": "42",
    "REPOSITORIES": "app,api",
    "MAX_VMS": "20",
    "IDLE_TIMEOUT_SECONDS": "900",
    "LOCK_BUCKET": "p-ghr-locks",
}


def test_reads_the_environment() -> None:
    config = Config.from_env(ENV)
    assert config.zones == ("zone-a", "zone-b")
    assert config.runner_label == "gcp-x64"
    assert config.runner_labels == ("self-hosted", "linux", "x64", "gcp-x64")
    assert config.installation_id == 42
    assert config.repositories == ("app", "api")
    assert (config.max_vms, config.idle_timeout_seconds, config.lock_bucket) == (20, 900, "p-ghr-locks")


def test_requires_a_zone() -> None:
    with pytest.raises(ValueError):
        Config.from_env({**ENV, "ZONES": " , "})
