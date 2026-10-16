from __future__ import annotations

import hashlib
import hmac
import json
import sys
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ghr.compute import AlreadyExists, ZoneUnavailable  # noqa: E402
from ghr.config import Config  # noqa: E402
from ghr.github import RunnerNameTaken  # noqa: E402
from ghr.lock import LockTimeout  # noqa: E402

SECRET = b"webhook-secret"
NOW = 1_800_000_000.0


def make_config(**overrides: Any) -> Config:
    values: dict[str, Any] = {
        "project": "test-project",
        "zones": ("zone-a", "zone-b", "zone-c"),
        "instance_template": "projects/test-project/global/instanceTemplates/ghr-runner-1",
        "name_prefix": "ghr",
        "runner_label": "gcp-x64",
        "runner_group": "gcp-runners",
        "github_org": "example-org",
        "app_id": "1",
        "installation_id": 42,
        "repositories": (),
        "max_vms": 5,
        "idle_timeout_seconds": 900,
        "lock_bucket": "test-locks",
    }
    values.update(overrides)
    return Config(**values)


def sign(body: bytes, secret: bytes = SECRET) -> str:
    return "sha256=" + hmac.new(secret, body, hashlib.sha256).hexdigest()


def webhook_request(action: str, job: dict[str, Any], private: bool = True, **payload: Any) -> tuple[dict[str, str], bytes]:
    body = json.dumps(
        {
            "action": action,
            "workflow_job": job,
            "repository": {"full_name": "example-org/app", "private": private},
            "organization": {"login": "example-org"},
            "installation": {"id": 42},
            **payload,
        }
    ).encode()
    return {"X-GitHub-Event": "workflow_job", "X-Hub-Signature-256": sign(body)}, body


def job(job_id: int = 1001, labels: tuple[str, ...] = ("self-hosted", "gcp-x64"), **fields: Any) -> dict[str, Any]:
    return {"id": job_id, "labels": list(labels), "runner_name": None, **fields}


def instance(
    name: str,
    status: str = "RUNNING",
    zone: str = "zone-a",
    age_seconds: float = 60,
    labels: dict[str, str] | None = None,
) -> dict[str, Any]:
    from datetime import datetime, timezone

    created = datetime.fromtimestamp(NOW - age_seconds, tz=timezone.utc).isoformat()
    result: dict[str, Any] = {
        "name": name,
        "status": status,
        "zone": f"https://example/zones/{zone}",
        "creationTimestamp": created,
    }
    if labels is not None:
        result["labels"] = labels
    return result


@dataclass
class FakeGitHub:
    group: dict[str, Any] = field(default_factory=lambda: {"id": 7, "name": "gcp-runners", "allows_public_repositories": False})
    runners: dict[str, dict[str, Any]] = field(default_factory=dict)
    jobs: dict[str, list[dict[str, Any]]] = field(default_factory=dict)
    public_repositories: set[str] = field(default_factory=set)
    refuse_delete: set[int] = field(default_factory=set)
    next_id: int = 500
    jit_calls: list[tuple[str, int, tuple[str, ...]]] = field(default_factory=list)
    deleted: list[int] = field(default_factory=list)

    def runner_group(self, name: str) -> dict[str, Any]:
        return self.group

    def generate_jit_config(self, name: str, runner_group_id: int, labels: tuple[str, ...]) -> tuple[int, str]:
        if name in self.runners:
            raise RunnerNameTaken(name)
        self.jit_calls.append((name, runner_group_id, labels))
        self.next_id += 1
        self.runners[name] = {"id": self.next_id, "name": name, "busy": False, "status": "offline"}
        return self.next_id, f"jit-{name}"

    def list_runners(self, name_prefix: str) -> list[dict[str, Any]]:
        return [r for r in self.runners.values() if r["name"].startswith(name_prefix)]

    def delete_runner(self, runner_id: int) -> bool:
        if runner_id in self.refuse_delete:
            return False
        self.deleted.append(runner_id)
        self.runners = {n: r for n, r in self.runners.items() if r["id"] != runner_id}
        return True

    def repository(self, name: str) -> dict[str, Any]:
        return {"name": name, "private": name not in self.public_repositories}

    def queued_jobs(self, repository: str) -> list[dict[str, Any]]:
        return self.jobs.get(repository, [])


@dataclass
class FakeCompute:
    instances: dict[str, dict[str, Any]] = field(default_factory=dict)
    full_zones: set[str] = field(default_factory=set)
    fail_insert: Exception | None = None
    race_on_insert: bool = False
    # The labels of each instance template, as runner.tf sets them.
    template_labels: dict[str, dict[str, str]] = field(
        default_factory=lambda: {
            "projects/test-project/global/instanceTemplates/ghr-runner-1": {"ghr_managed": "true", "ghr_pool": "ghr"},
            "projects/test-project/global/instanceTemplates/ghr-heavy-1": {
                "ghr_managed": "true",
                "ghr_pool": "ghr",
                "ghr_class": "heavy",
            },
        }
    )
    inserts: list[tuple[str, str, dict[str, str]]] = field(default_factory=list)
    templates: list[str] = field(default_factory=list)
    deleted: list[str] = field(default_factory=list)

    def list_instances(self) -> list[dict[str, Any]]:
        return list(self.instances.values())

    def find(self, name: str) -> dict[str, Any] | None:
        return self.instances.get(name)

    def insert(self, zone: str, name: str, template: str, metadata: dict[str, str]) -> dict[str, Any]:
        self.inserts.append((zone, name, metadata))
        self.templates.append(template)
        if self.fail_insert:
            raise self.fail_insert
        if self.race_on_insert:
            raise AlreadyExists(name)
        if zone in self.full_zones:
            # Compute Engine accepts the request; the operation fails later.
            return {"zone": zone, "full": True}
        # The real insert copies the labels of the instance template.
        created = instance(name, "PROVISIONING", zone, age_seconds=0, labels=dict(self.template_labels[template]))
        self.instances[name] = created
        return {"zone": zone, "full": False}

    def wait(self, zone: str, operation: dict[str, Any], deadline: float) -> bool:
        if operation["full"]:
            raise ZoneUnavailable(zone)
        return True

    def delete(self, inst: dict[str, Any]) -> None:
        self.deleted.append(inst["name"])
        self.instances.pop(inst["name"], None)


@dataclass
class FakeLock:
    """Records how often the lock was held. on_acquire simulates other instances."""

    times_held: int = 0
    timeout: bool = False
    on_acquire: Any = None

    @contextmanager
    def held(self, deadline: float) -> Iterator[None]:
        if self.timeout:
            raise LockTimeout("busy")
        if self.on_acquire:
            self.on_acquire()
        self.times_held += 1
        yield


@pytest.fixture
def github() -> FakeGitHub:
    return FakeGitHub()


@pytest.fixture
def compute() -> FakeCompute:
    return FakeCompute()


@pytest.fixture
def lock() -> FakeLock:
    return FakeLock()
