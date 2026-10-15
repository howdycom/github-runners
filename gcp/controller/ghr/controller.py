"""Decides when to create and delete runner VMs."""

from __future__ import annotations

import json
import re
import secrets
import time
from collections.abc import Callable, Iterable, Mapping
from contextlib import AbstractContextManager
from datetime import datetime
from typing import Any, Protocol

from . import log
from .compute import ACTIVE_STATES, FINISHED_STATES, AlreadyExists, ZoneUnavailable, created_at
from .config import Config
from .github import RunnerNameTaken, verify_signature
from .lock import LockTimeout

# GitHub waits 10 seconds for a webhook response.
WEBHOOK_DEADLINE_SECONDS = 8.0
# Time to wait for each VM the reconcile job starts.
RECONCILE_DEADLINE_SECONDS = 5.0
# A queued job gets this long for its webhook to start a VM before the
# reconcile job starts one.
QUEUE_GRACE_SECONDS = 120
# The reconcile job starts at most this many VMs per pass.
RECONCILE_MAX_STARTS = 10
# Cloud Scheduler runs the reconcile job this often (controller.tf).
RECONCILE_INTERVAL_SECONDS = 120
RUNNER_GROUP_CACHE_SECONDS = 600
# Each runner registration gets a random suffix after its VM's name, so two
# attempts for one job never share a runner name.
RUNNER_SUFFIX_BYTES = 3


class UnsafeRunnerGroup(Exception):
    pass


class GitHubPort(Protocol):
    def runner_group(self, name: str) -> dict[str, Any]: ...
    def generate_jit_config(self, name: str, runner_group_id: int, labels: tuple[str, ...]) -> tuple[int, str]: ...
    def list_runners(self, name_prefix: str) -> list[dict[str, Any]]: ...
    def delete_runner(self, runner_id: int) -> bool: ...
    def queued_jobs(self, repository: str) -> list[dict[str, Any]]: ...


class ComputePort(Protocol):
    def list_instances(self) -> list[dict[str, Any]]: ...
    def find(self, name: str) -> dict[str, Any] | None: ...
    def insert(self, zone: str, name: str, template: str, metadata: dict[str, str]) -> dict[str, Any]: ...
    def wait(self, zone: str, operation: dict[str, Any], deadline: float) -> bool: ...
    def delete(self, instance: dict[str, Any]) -> None: ...


class LockPort(Protocol):
    def held(self, deadline: float) -> AbstractContextManager[None]: ...


def wants_runner(config: Config, job_labels: Iterable[str]) -> bool:
    """True when every runs-on label of the job is one our runners have."""
    labels = {label.lower() for label in job_labels}
    return config.runner_label in labels and labels <= set(config.runner_labels)


def zone_order(zones: tuple[str, ...], job_id: int, attempt: int = 0) -> list[str]:
    """Spreads jobs over zones. A new attempt starts at the next zone."""
    start = (job_id + attempt) % len(zones)
    return [*zones[start:], *zones[:start]]


class Controller:
    def __init__(
        self,
        config: Config,
        github: GitHubPort,
        compute: ComputePort,
        lock: LockPort,
        clock: Callable[[], float] = time.time,
        monotonic: Callable[[], float] = time.monotonic,
        runner_suffix: Callable[[], str] = lambda: secrets.token_hex(RUNNER_SUFFIX_BYTES),
    ) -> None:
        self._config = config
        self._github = github
        self._compute = compute
        self._lock = lock
        self._clock = clock
        self._monotonic = monotonic
        self._runner_suffix = runner_suffix
        self._runner_name = re.compile(rf"^({re.escape(config.name_prefix)}-.+)-[0-9a-f]{{{RUNNER_SUFFIX_BYTES * 2}}}$")
        self._group_id: int | None = None
        self._group_checked_at = 0.0

    def vm_name(self, job_id: int) -> str:
        return f"{self._config.name_prefix}-{job_id}"

    def _vm_of_runner(self, runner_name: str) -> str | None:
        """The VM a runner registration belongs to, or None if it is not ours."""
        match = self._runner_name.match(runner_name)
        return match.group(1) if match else None

    def _runners_by_vm(self, runners: Iterable[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
        by_vm: dict[str, list[dict[str, Any]]] = {}
        for runner in runners:
            vm = self._vm_of_runner(runner["name"])
            if vm:
                by_vm.setdefault(vm, []).append(runner)
        return by_vm

    # --- Webhook --------------------------------------------------------------

    def handle_webhook(self, headers: Mapping[str, str], body: bytes, secret: bytes) -> tuple[int, dict[str, Any]]:
        if not verify_signature(secret, body, headers.get("X-Hub-Signature-256")):
            return 401, {"error": "invalid signature"}

        event = headers.get("X-GitHub-Event")
        if event == "ping":
            return 200, {"result": "pong"}
        if event != "workflow_job":
            return 202, {"result": "ignored", "reason": f"event {event}"}

        payload = json.loads(body)
        if (payload.get("installation") or {}).get("id") != self._config.installation_id:
            return 403, {"error": "unknown installation"}
        org = (payload.get("organization") or {}).get("login", "")
        if org.lower() != self._config.github_org.lower():
            return 403, {"error": "unknown organization"}

        job = payload["workflow_job"]
        action = payload.get("action")
        if action == "queued":
            return self._on_queued(job, payload["repository"])
        if action == "completed":
            return self._on_completed(job)
        return 202, {"result": "ignored", "reason": f"action {action}"}

    def _on_queued(self, job: dict[str, Any], repository: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        if not wants_runner(self._config, job.get("labels", [])):
            return 202, {"result": "ignored", "reason": "labels"}
        if repository.get("private") is not True:
            log.warning("ignored job from a public repository", repository=repository.get("full_name"), job_id=job["id"])
            return 202, {"result": "ignored", "reason": "public repository"}
        result = self.start_runner(int(job["id"]), self._monotonic() + WEBHOOK_DEADLINE_SECONDS)
        return 200, {"result": result}

    def _on_completed(self, job: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        runner_name = job.get("runner_name") or ""
        vm = self._vm_of_runner(runner_name)
        if vm:
            instance = self._compute.find(vm)
            if instance:
                self._compute.delete(instance)
                log.info("deleted runner vm after job", vm=vm, runner=runner_name, job_id=job["id"])
                return 200, {"result": "deleted"}
            return 200, {"result": "already gone"}

        # The job ended without one of our runners, for example it was
        # cancelled while queued. The VM started for it may still be idle.
        if not runner_name and wants_runner(self._config, job.get("labels", [])):
            return 200, {"result": self._retire_if_idle(self.vm_name(int(job["id"])))}
        return 202, {"result": "ignored"}

    # --- Starting runners -----------------------------------------------------

    def start_runner(self, job_id: int, deadline: float, attempt: int = 0) -> str:
        """Creates the VM for a queued job. Safe to call more than once per job.

        The attempt number rotates the zone order, so a retry after a late
        capacity failure does not start in the same zone again.
        """
        name = self.vm_name(job_id)
        # Cheap checks first, so duplicates and a full pool cost no GitHub call.
        blocked = self._blocked(name, job_id)
        if blocked:
            return blocked

        runner_id, jit_config = self._register_runner(name)
        try:
            result = self._create_vm(job_id, name, jit_config, deadline, attempt)
        except Exception:
            self._github.delete_runner(runner_id)
            raise
        if result != "created":
            self._github.delete_runner(runner_id)
        return result

    def _blocked(self, name: str, job_id: int) -> str | None:
        """Why no VM may be created for this job now, or None."""
        instances = self._compute.list_instances()
        if any(instance["name"] == name for instance in instances):
            return "exists"
        if sum(1 for instance in instances if instance["status"] in ACTIVE_STATES) >= self._config.max_vms:
            log.warning("at max_vms; the job waits for the next reconcile pass", job_id=job_id, max_vms=self._config.max_vms)
            return "at capacity"
        return None

    def _create_vm(self, job_id: int, name: str, jit_config: str, deadline: float, attempt: int) -> str:
        for zone in zone_order(self._config.zones, job_id, attempt):
            try:
                # Every function instance takes this lock between its check and
                # its insert, so two requests cannot both pass the check.
                with self._lock.held(deadline):
                    blocked = self._blocked(name, job_id)
                    if blocked:
                        return blocked
                    operation = self._compute.insert(zone, name, self._config.instance_template, {"jit-config": jit_config})
            except LockTimeout:
                log.warning("start lock busy; the job waits for the next reconcile pass", vm=name, job_id=job_id)
                return "busy"
            except AlreadyExists:
                return "exists"

            try:
                started = self._compute.wait(zone, operation, deadline)
            except ZoneUnavailable as exc:
                log.warning("zone has no capacity, trying the next one", vm=name, zone=zone, detail=str(exc))
                continue
            if started:
                log.info("created runner vm", vm=name, zone=zone, job_id=job_id)
            else:
                log.info(
                    "runner vm still starting at the deadline; reconcile retries in another zone if it fails",
                    vm=name,
                    zone=zone,
                    job_id=job_id,
                )
            return "created"

        log.error("no zone had capacity; the job waits for the next reconcile pass", vm=name, zones=self._config.zones)
        return "no capacity"

    def _register_runner(self, vm: str) -> tuple[int, str]:
        """Registers a runner for the VM under a new, unique name.

        A unique name means no request ever has to delete a runner by name,
        which could remove a runner that a concurrent request just handed to
        its VM.
        """
        group_id = self._runner_group_id()
        try:
            return self._github.generate_jit_config(f"{vm}-{self._runner_suffix()}", group_id, self._config.runner_labels)
        except RunnerNameTaken:
            # Two random suffixes collided; a new one will not.
            return self._github.generate_jit_config(f"{vm}-{self._runner_suffix()}", group_id, self._config.runner_labels)

    def _runner_group_id(self) -> int:
        if self._group_id is not None and self._clock() - self._group_checked_at < RUNNER_GROUP_CACHE_SECONDS:
            return self._group_id
        group = self._github.runner_group(self._config.runner_group)
        if group.get("allows_public_repositories"):
            raise UnsafeRunnerGroup(
                f"runner group {self._config.runner_group!r} allows public repositories; refusing to register runners"
            )
        self._group_id = int(group["id"])
        self._group_checked_at = self._clock()
        return self._group_id

    # --- Retiring runners -----------------------------------------------------

    def _retire_if_idle(self, vm: str) -> str:
        instance = self._compute.find(vm)
        if instance is None:
            return "no vm"
        runners = self._runners_by_vm(self._github.list_runners(f"{vm}-")).get(vm, [])
        if any(runner["busy"] for runner in runners):
            return "busy"
        if not all(self._github.delete_runner(runner["id"]) for runner in runners):
            return "busy"
        self._compute.delete(instance)
        log.info("deleted idle runner vm", vm=vm)
        return "deleted"

    # --- Reconcile ------------------------------------------------------------

    def reconcile(self) -> dict[str, int]:
        """Cleans up VMs and runners, and starts VMs for jobs whose webhook was lost."""
        summary = {"finished": 0, "idle": 0, "orphan_runners": 0, "started": 0, "errors": 0}
        now = self._clock()
        prefix = f"{self._config.name_prefix}-"
        instances = self._compute.list_instances()
        runners = self._runners_by_vm(self._github.list_runners(prefix))
        vm_names = {i["name"] for i in instances}

        for instance in instances:
            name = instance["name"]
            try:
                if instance["status"] in FINISHED_STATES:
                    self._compute.delete(instance)
                    summary["finished"] += 1
                elif instance["status"] in ACTIVE_STATES and now - created_at(instance) >= self._config.idle_timeout_seconds:
                    vm_runners = runners.get(name, [])
                    if not vm_runners:
                        # Never registered, or its job ended and the VM did not power off.
                        self._compute.delete(instance)
                        summary["idle"] += 1
                    elif not any(r["busy"] for r in vm_runners) and all(
                        self._github.delete_runner(r["id"]) for r in vm_runners
                    ):
                        self._compute.delete(instance)
                        summary["idle"] += 1
            except Exception as exc:
                summary["errors"] += 1
                log.error("reconcile failed for vm", vm=name, detail=str(exc))

        for vm, vm_runners in runners.items():
            if vm in vm_names:
                continue
            for runner in vm_runners:
                if runner["busy"] or runner["status"] != "offline":
                    continue
                try:
                    # Check again: the webhook may have just created this VM.
                    if self._compute.find(vm) is None and self._github.delete_runner(runner["id"]):
                        summary["orphan_runners"] += 1
                except Exception as exc:
                    summary["errors"] += 1
                    log.error("reconcile failed for runner", runner=runner["name"], detail=str(exc))

        for job in self._missed_jobs(now, vm_names):
            if summary["started"] >= RECONCILE_MAX_STARTS:
                break
            # The webhook made attempt 0. Each reconcile pass since then is one
            # more attempt, so retries move through the zones.
            attempt = max(1, int((now - _timestamp(job["created_at"])) // RECONCILE_INTERVAL_SECONDS))
            try:
                result = self.start_runner(int(job["id"]), self._monotonic() + RECONCILE_DEADLINE_SECONDS, attempt)
            except Exception as exc:
                summary["errors"] += 1
                log.error("reconcile failed to start a runner", job_id=job["id"], detail=str(exc))
                continue
            if result == "created":
                summary["started"] += 1
            elif result in ("at capacity", "no capacity", "busy"):
                break

        log.info("reconcile pass", **summary)
        return summary

    def _missed_jobs(self, now: float, vm_names: set[str]) -> list[dict[str, Any]]:
        missed = []
        for repository in self._config.repositories:
            try:
                jobs = self._github.queued_jobs(repository)
            except Exception as exc:
                log.error("could not list queued jobs", repository=repository, detail=str(exc))
                continue
            for job in jobs:
                if not wants_runner(self._config, job.get("labels", [])):
                    continue
                if now - _timestamp(job["created_at"]) < QUEUE_GRACE_SECONDS:
                    continue
                if self.vm_name(int(job["id"])) in vm_names:
                    continue
                missed.append(job)
        return missed


def _timestamp(value: str) -> float:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
