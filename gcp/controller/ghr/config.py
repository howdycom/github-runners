"""Controller settings, read from the environment Terraform sets."""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass

# Labels every runner registers with. A job is ours only when all of its
# runs-on labels are in this set and it asks for the custom label.
DEFAULT_RUNNER_LABELS = ("self-hosted", "linux", "x64")


def _split(value: str) -> tuple[str, ...]:
    return tuple(item.strip() for item in value.split(",") if item.strip())


@dataclass(frozen=True)
class RunnerPool:
    """One machine size. A job matches at most one pool, by its custom label."""

    name: str
    label: str
    template: str
    # Tried in order when no zone has capacity for the template above.
    fallback_templates: tuple[str, ...] = ()

    @property
    def runner_labels(self) -> tuple[str, ...]:
        return (*DEFAULT_RUNNER_LABELS, self.label)

    @property
    def templates(self) -> tuple[str, ...]:
        return (self.template, *self.fallback_templates)


@dataclass(frozen=True)
class Config:
    project: str
    zones: tuple[str, ...]
    instance_template: str
    name_prefix: str
    runner_label: str
    runner_group: str
    github_org: str
    app_id: str
    installation_id: int
    repositories: tuple[str, ...]
    idle_timeout_seconds: int
    # Empty template disables the heavy pool. Existing deploys keep one size.
    heavy_instance_template: str = ""
    heavy_runner_label: str = "gcp-x64-heavy"
    # Other machine types for the heavy pool, used in order when no zone has
    # capacity for heavy_instance_template.
    heavy_fallback_instance_templates: tuple[str, ...] = ()

    def standard_pool(self) -> RunnerPool:
        return RunnerPool("standard", self.runner_label, self.instance_template)

    def heavy_pool(self) -> RunnerPool | None:
        if not self.heavy_instance_template:
            return None
        return RunnerPool(
            "heavy",
            self.heavy_runner_label,
            self.heavy_instance_template,
            self.heavy_fallback_instance_templates,
        )

    def pools(self) -> tuple[RunnerPool, ...]:
        heavy = self.heavy_pool()
        if heavy is None:
            return (self.standard_pool(),)
        return (self.standard_pool(), heavy)

    @classmethod
    def from_env(cls, env: Mapping[str, str] = os.environ) -> Config:
        zones = _split(env["ZONES"])
        if not zones:
            raise ValueError("ZONES must list at least one zone")
        runner_label = env["RUNNER_LABEL"].lower()
        heavy_template = env.get("HEAVY_INSTANCE_TEMPLATE", "").strip()
        heavy_label = env.get("HEAVY_RUNNER_LABEL", "gcp-x64-heavy").strip().lower()
        heavy_fallbacks = _split(env.get("HEAVY_FALLBACK_INSTANCE_TEMPLATES", ""))
        if heavy_template and heavy_label == runner_label:
            raise ValueError("HEAVY_RUNNER_LABEL must differ from RUNNER_LABEL")
        if heavy_fallbacks and not heavy_template:
            raise ValueError("HEAVY_FALLBACK_INSTANCE_TEMPLATES needs HEAVY_INSTANCE_TEMPLATE")
        return cls(
            project=env["GCP_PROJECT"],
            zones=zones,
            instance_template=env["INSTANCE_TEMPLATE"],
            name_prefix=env["NAME_PREFIX"],
            runner_label=runner_label,
            runner_group=env["RUNNER_GROUP"],
            github_org=env["GITHUB_ORG"],
            app_id=env["GITHUB_APP_ID"],
            installation_id=int(env["GITHUB_INSTALLATION_ID"]),
            repositories=_split(env.get("REPOSITORIES", "")),
            idle_timeout_seconds=int(env["IDLE_TIMEOUT_SECONDS"]),
            heavy_instance_template=heavy_template,
            heavy_runner_label=heavy_label,
            heavy_fallback_instance_templates=heavy_fallbacks,
        )
