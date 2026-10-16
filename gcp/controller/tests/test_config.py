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
    assert config.standard_pool().runner_labels == ("self-hosted", "linux", "x64", "gcp-x64")
    assert config.installation_id == 42
    assert config.repositories == ("app", "api")
    assert (config.max_vms, config.idle_timeout_seconds, config.lock_bucket) == (20, 900, "p-ghr-locks")


def test_requires_a_zone() -> None:
    with pytest.raises(ValueError):
        Config.from_env({**ENV, "ZONES": " , "})


def test_heavy_pool_is_off_unless_configured() -> None:
    config = Config.from_env(ENV)
    assert config.heavy_instance_template == ""
    assert config.heavy_pool() is None
    assert config.pools() == (config.standard_pool(),)


def test_reads_the_heavy_pool() -> None:
    config = Config.from_env(
        {
            **ENV,
            "HEAVY_INSTANCE_TEMPLATE": "projects/p/global/instanceTemplates/heavy",
            "HEAVY_RUNNER_LABEL": "GCP-X64-HEAVY",
            "MAX_HEAVY_VMS": "12",
        }
    )
    heavy = config.heavy_pool()
    assert heavy is not None
    assert heavy.name == "heavy"
    assert heavy.label == "gcp-x64-heavy"
    assert heavy.template == "projects/p/global/instanceTemplates/heavy"
    assert heavy.max_vms == 12
    assert heavy.runner_labels == ("self-hosted", "linux", "x64", "gcp-x64-heavy")


def test_rejects_one_label_for_both_pools() -> None:
    with pytest.raises(ValueError, match="HEAVY_RUNNER_LABEL"):
        Config.from_env(
            {
                **ENV,
                "HEAVY_INSTANCE_TEMPLATE": "projects/p/global/instanceTemplates/heavy",
                "HEAVY_RUNNER_LABEL": "gcp-x64",
                "MAX_HEAVY_VMS": "1",
            }
        )


def test_rejects_a_heavy_pool_with_no_capacity() -> None:
    with pytest.raises(ValueError, match="MAX_HEAVY_VMS"):
        Config.from_env(
            {
                **ENV,
                "HEAVY_INSTANCE_TEMPLATE": "projects/p/global/instanceTemplates/heavy",
                "HEAVY_RUNNER_LABEL": "gcp-x64-heavy",
                "MAX_HEAVY_VMS": "0",
            }
        )
