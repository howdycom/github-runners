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
    "IDLE_TIMEOUT_SECONDS": "900",
}


def test_reads_the_environment() -> None:
    config = Config.from_env(ENV)
    assert config.zones == ("zone-a", "zone-b")
    assert config.runner_label == "gcp-x64"
    assert config.standard_pool().runner_labels == ("self-hosted", "linux", "x64", "gcp-x64")
    assert config.installation_id == 42
    assert config.repositories == ("app", "api")
    assert config.idle_timeout_seconds == 900


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
        }
    )
    heavy = config.heavy_pool()
    assert heavy is not None
    assert heavy.name == "heavy"
    assert heavy.label == "gcp-x64-heavy"
    assert heavy.template == "projects/p/global/instanceTemplates/heavy"
    assert heavy.runner_labels == ("self-hosted", "linux", "x64", "gcp-x64-heavy")


def test_rejects_one_label_for_both_pools() -> None:
    with pytest.raises(ValueError, match="HEAVY_RUNNER_LABEL"):
        Config.from_env(
            {
                **ENV,
                "HEAVY_INSTANCE_TEMPLATE": "projects/p/global/instanceTemplates/heavy",
                "HEAVY_RUNNER_LABEL": "gcp-x64",
            }
        )


HEAVY_ENV = {
    **ENV,
    "HEAVY_INSTANCE_TEMPLATE": "projects/p/global/instanceTemplates/heavy",
    "HEAVY_RUNNER_LABEL": "gcp-x64-heavy",
}


def test_reads_the_heavy_fallback_machine_types_in_order() -> None:
    config = Config.from_env(
        {
            **HEAVY_ENV,
            "HEAVY_FALLBACK_INSTANCE_TEMPLATES": "projects/p/global/instanceTemplates/n2, projects/p/global/instanceTemplates/n2d,",
        }
    )
    heavy = config.heavy_pool()
    assert heavy is not None
    assert heavy.templates == (
        "projects/p/global/instanceTemplates/heavy",
        "projects/p/global/instanceTemplates/n2",
        "projects/p/global/instanceTemplates/n2d",
    )


def test_pools_have_no_fallback_unless_configured() -> None:
    config = Config.from_env(HEAVY_ENV)
    heavy = config.heavy_pool()
    assert heavy is not None and heavy.templates == ("projects/p/global/instanceTemplates/heavy",)
    assert config.standard_pool().templates == ("projects/p/global/instanceTemplates/t",)


def test_rejects_fallbacks_without_a_heavy_pool() -> None:
    with pytest.raises(ValueError, match="HEAVY_FALLBACK_INSTANCE_TEMPLATES"):
        Config.from_env({**ENV, "HEAVY_FALLBACK_INSTANCE_TEMPLATES": "projects/p/global/instanceTemplates/n2"})
