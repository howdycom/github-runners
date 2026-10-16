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
    max_vms: int

    @property
    def runner_labels(self) -> tuple[str, ...]:
        return (*DEFAULT_RUNNER_LABELS, self.label)


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
    max_vms: int
    idle_timeout_seconds: int
    lock_bucket: str
    # Empty template disables the heavy pool. Existing deploys keep one size.
    heavy_instance_template: str = ""
    heavy_runner_label: str = "gcp-x64-heavy"
    max_heavy_vms: int = 0

    def light_pool(self) -> RunnerPool:
        return RunnerPool("light", self.runner_label, self.instance_template, self.max_vms)

    def heavy_pool(self) -> RunnerPool | None:
        if not self.heavy_instance_template:
            return None
        return RunnerPool("heavy", self.heavy_runner_label, self.heavy_instance_template, self.max_heavy_vms)

    def pools(self) -> tuple[RunnerPool, ...]:
        heavy = self.heavy_pool()
        if heavy is None:
            return (self.light_pool(),)
        return (self.light_pool(), heavy)

    @classmethod
    def from_env(cls, env: Mapping[str, str] = os.environ) -> Config:
        zones = _split(env["ZONES"])
        if not zones:
            raise ValueError("ZONES must list at least one zone")
        runner_label = env["RUNNER_LABEL"].lower()
        heavy_template = env.get("HEAVY_INSTANCE_TEMPLATE", "").strip()
        heavy_label = env.get("HEAVY_RUNNER_LABEL", "gcp-x64-heavy").strip().lower()
        max_heavy_vms = int(env.get("MAX_HEAVY_VMS") or "0")
        if heavy_template and heavy_label == runner_label:
            raise ValueError("HEAVY_RUNNER_LABEL must differ from RUNNER_LABEL")
        if heavy_template and max_heavy_vms < 1:
            raise ValueError("MAX_HEAVY_VMS must be at least 1 when the heavy pool is enabled")
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
            max_vms=int(env["MAX_VMS"]),
            idle_timeout_seconds=int(env["IDLE_TIMEOUT_SECONDS"]),
            lock_bucket=env["LOCK_BUCKET"],
            heavy_instance_template=heavy_template,
            heavy_runner_label=heavy_label,
            max_heavy_vms=max_heavy_vms,
        )
