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

    @property
    def runner_labels(self) -> tuple[str, ...]:
        return (*DEFAULT_RUNNER_LABELS, self.runner_label)

    @classmethod
    def from_env(cls, env: Mapping[str, str] = os.environ) -> Config:
        zones = _split(env["ZONES"])
        if not zones:
            raise ValueError("ZONES must list at least one zone")
        return cls(
            project=env["GCP_PROJECT"],
            zones=zones,
            instance_template=env["INSTANCE_TEMPLATE"],
            name_prefix=env["NAME_PREFIX"],
            runner_label=env["RUNNER_LABEL"].lower(),
            runner_group=env["RUNNER_GROUP"],
            github_org=env["GITHUB_ORG"],
            app_id=env["GITHUB_APP_ID"],
            installation_id=int(env["GITHUB_INSTALLATION_ID"]),
            repositories=_split(env.get("REPOSITORIES", "")),
            max_vms=int(env["MAX_VMS"]),
            idle_timeout_seconds=int(env["IDLE_TIMEOUT_SECONDS"]),
            lock_bucket=env["LOCK_BUCKET"],
        )
