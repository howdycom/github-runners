"""Decides when to create and delete runner VMs."""

from __future__ import annotations

import json
import re
import secrets
import time
from collections.abc import Callable, Iterable, Mapping
from enum import StrEnum
from typing import Any, Protocol

from . import log
from .compute import ACTIVE_STATES, FINISHED_STATES, AlreadyExists, ZoneUnavailable, created_at
from .config import Config, RunnerPool
from .github import RunnerNameTaken, verify_signature
from .timestamps import parse_timestamp

# GitHub waits 10 seconds for a webhook response.
WEBHOOK_DEADLINE_SECONDS = 8.0
# A queued job gets this long for its webhook to start a VM before the
# reconcile job starts one. Longer than the webhook function timeout (30s),
# so a request that is still creating a VM is not duplicated.
QUEUE_GRACE_SECONDS = 45
# The reconcile job starts at most this many VMs per pass. Each start sends
# the create and returns. The function timeout is 110s, so 40 leaves time for
# the cleanup scan and the GitHub calls.
RECONCILE_MAX_STARTS = 40
# Cloud Scheduler runs the reconcile job this often (controller.tf).
RECONCILE_INTERVAL_SECONDS = 60
RUNNER_GROUP_CACHE_SECONDS = 600
# Each runner registration is named <vm>-<suffix>. The suffix is the
# registration time (8 hex digits of Unix seconds) plus 4 random hex digits, so
# two attempts for one job never share a name, and reconcile can tell how old
# a registration is. GitHub does not report that itself.
RUNNER_RANDOM_BYTES = 2
# A runner registered this recently may still be waiting for its VM: the
# webhook registers it before it creates the VM.
ORPHAN_GRACE_SECONDS = 300


class UnsafeRunnerGroup(Exception):
    pass


class StartResult(StrEnum):
    """Outcome of start_runner. The value is what the webhook returns."""

    CREATED = "created"
    EXISTS = "exists"
    NO_CAPACITY = "no capacity"


class GitHubPort(Protocol):
    def runner_group(self, name: str) -> dict[str, Any]: ...
    def generate_jit_config(self, name: str, runner_group_id: int, labels: tuple[str, ...]) -> tuple[int, str]: ...
    def list_runners(self, name_prefix: str) -> list[dict[str, Any]]: ...
    def delete_runner(self, runner_id: int) -> bool: ...
    def repository(self, name: str) -> dict[str, Any]: ...
    def queued_jobs(self, repository: str) -> list[dict[str, Any]]: ...


class ComputePort(Protocol):
    def list_instances(self) -> list[dict[str, Any]]: ...
    def find(self, name: str) -> dict[str, Any] | None: ...
    def insert(self, zone: str, name: str, template: str, metadata: dict[str, str]) -> dict[str, Any]: ...
    def wait(self, zone: str, operation: dict[str, Any], deadline: float) -> bool: ...
    def delete(self, instance: dict[str, Any]) -> None: ...


def pool_for(config: Config, job_labels: Iterable[str]) -> RunnerPool | None:
    """The one pool whose label the job asks for.

    A job that asks for two pool labels matches neither. A heavy runner
    registers only its own label, so it cannot take a standard job, and a
    standard runner cannot take a heavy job.
    """
    labels = {label.lower() for label in job_labels}
    matched = [pool for pool in config.pools() if pool.label in labels and labels <= set(pool.runner_labels)]
    if len(matched) != 1:
        return None
    return matched[0]


def wants_runner(config: Config, job_labels: Iterable[str]) -> bool:
    """True when every runs-on label of the job is one our runners have."""
    return pool_for(config, job_labels) is not None


def vm_class(instance: dict[str, Any]) -> str:
    """standard or heavy. A VM from before the heavy pool has no class and is standard."""
    labels = instance.get("labels") or {}
    value = labels.get("ghr_class", "standard")
    return value if isinstance(value, str) else "standard"


def zone_order(zones: tuple[str, ...], job_id: int, attempt: int = 0) -> list[str]:
    """Spreads jobs over zones. A new attempt starts at the next zone."""
    start = (job_id + attempt) % len(zones)
    return [*zones[start:], *zones[:start]]


def template_order(templates: tuple[str, ...], zones: tuple[str, ...], attempt: int = 0) -> list[str]:
    """The machine types to try, in order. Each one gets one attempt per zone, then the next one starts.

    The reconcile job does not wait for a create, so it never sees a capacity
    failure that arrives later. Without this, its retries would only rotate
    the zones of the first machine type and never reach a fallback.
    """
    start = (attempt // len(zones)) % len(templates)
    return [*templates[start:], *templates[:start]]


class Controller:
    def __init__(
        self,
        config: Config,
        github: GitHubPort,
        compute: ComputePort,
        clock: Callable[[], float] = time.time,
        monotonic: Callable[[], float] = time.monotonic,
        runner_suffix: Callable[[], str] | None = None,
    ) -> None:
        self._config = config
        self._github = github
        self._compute = compute
        self._clock = clock
        self._monotonic = monotonic
        self._runner_suffix = runner_suffix or self._new_runner_suffix
        self._runner_name = re.compile(
            rf"^({re.escape(config.name_prefix)}-.+)-([0-9a-f]{{8}})[0-9a-f]{{{RUNNER_RANDOM_BYTES * 2}}}$"
        )
        self._group_id: int | None = None
        self._group_checked_at = 0.0

    def vm_name(self, job_id: int) -> str:
        return f"{self._config.name_prefix}-{job_id}"

    def _new_runner_suffix(self) -> str:
        return f"{int(self._clock()):08x}{secrets.token_hex(RUNNER_RANDOM_BYTES)}"

    def _vm_of_runner(self, runner_name: str) -> str | None:
        """The VM a runner registration belongs to, or None if it is not ours."""
        match = self._runner_name.match(runner_name)
        return match.group(1) if match else None

    def _runners_by_vm(self, runners: Iterable[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
        """Our runners grouped by VM, each with registered_at (Unix seconds) from its name."""
        by_vm: dict[str, list[dict[str, Any]]] = {}
        for runner in runners:
            match = self._runner_name.match(runner["name"])
            if match:
                by_vm.setdefault(match.group(1), []).append({**runner, "registered_at": int(match.group(2), 16)})
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
        result = self.start_runner(
            int(job["id"]),
            self._monotonic() + WEBHOOK_DEADLINE_SECONDS,
            job_labels=job.get("labels", []),
        )
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

    def start_runner(
        self,
        job_id: int,
        deadline: float,
        attempt: int = 0,
        job_labels: Iterable[str] | None = None,
        name: str | None = None,
        wait_for_start: bool = True,
    ) -> StartResult:
        """Creates the VM for a queued job. Safe to call more than once per job.

        The attempt number rotates the zone order, so a retry after a late
        capacity failure does not start in the same zone again. job_labels
        selects the pool. Callers that omit them get the standard pool. name
        overrides the VM name, for a job whose own VM took another job.
        """
        pool = self._config.standard_pool() if job_labels is None else pool_for(self._config, job_labels)
        if pool is None:
            raise ValueError("job labels do not select one runner pool")
        name = name or self.vm_name(job_id)
        # A duplicate delivery costs no GitHub call.
        if self._exists(name):
            return StartResult.EXISTS

        runner_id, jit_config = self._register_runner(name, pool)
        try:
            result = self._create_vm(
                job_id, name, jit_config, deadline, attempt, pool, wait_for_start=wait_for_start
            )
        except Exception:
            self._github.delete_runner(runner_id)
            raise
        if result is not StartResult.CREATED:
            self._github.delete_runner(runner_id)
        return result

    def _exists(self, name: str) -> bool:
        return any(instance["name"] == name for instance in self._compute.list_instances())

    def _create_vm(
        self,
        job_id: int,
        name: str,
        jit_config: str,
        deadline: float,
        attempt: int,
        pool: RunnerPool,
        wait_for_start: bool = True,
    ) -> StartResult:
        # Every zone with the pool's own machine type first. A fallback type is
        # used only when no zone has capacity for the one before it, or after
        # the reconcile job tried the first type once in every zone.
        for index, template in enumerate(template_order(pool.templates, self._config.zones, attempt)):
            if index:
                log.warning("no zone had capacity; trying the fallback machine type", vm=name, template=template)
            for zone in zone_order(self._config.zones, job_id, attempt):
                try:
                    # No cap and no lock: every queued job gets a VM at once. The
                    # VM name is unique per job, so a duplicate request fails here.
                    operation = self._compute.insert(zone, name, template, {"jit-config": jit_config})
                except AlreadyExists:
                    return StartResult.EXISTS

                try:
                    # Reconcile checks the operation once. A create that is still
                    # running counts as started, so one pass can request many VMs.
                    # A zone that has already refused the create is tried next.
                    wait_deadline = deadline if wait_for_start else self._monotonic()
                    started = self._compute.wait(zone, operation, wait_deadline)
                except ZoneUnavailable as exc:
                    log.warning("zone has no capacity, trying the next one", vm=name, zone=zone, detail=str(exc))
                    continue
                if started:
                    log.info("created runner vm", vm=name, zone=zone, job_id=job_id, template=template)
                else:
                    log.info(
                        "runner vm still starting at the deadline; reconcile retries in another zone if it fails",
                        vm=name,
                        zone=zone,
                        job_id=job_id,
                        template=template,
                    )
                return StartResult.CREATED

        log.error("no zone had capacity; the job waits for the next reconcile pass", vm=name, zones=self._config.zones)
        return StartResult.NO_CAPACITY

    def _register_runner(self, vm: str, pool: RunnerPool) -> tuple[int, str]:
        """Registers a runner for the VM under a new, unique name.

        A unique name means no request ever has to delete a runner by name,
        which could remove a runner that a concurrent request just handed to
        its VM. The runner carries only this pool's label, so it cannot take
        a job that asked for the other pool.
        """
        group_id = self._runner_group_id()
        try:
            return self._github.generate_jit_config(f"{vm}-{self._runner_suffix()}", group_id, pool.runner_labels)
        except RunnerNameTaken:
            # Two random suffixes collided; a new one will not.
            return self._github.generate_jit_config(f"{vm}-{self._runner_suffix()}", group_id, pool.runner_labels)

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
        removed: set[str] = set()

        for instance in instances:
            name = instance["name"]
            try:
                if instance["status"] in FINISHED_STATES:
                    self._compute.delete(instance)
                    removed.add(name)
                    summary["finished"] += 1
                elif instance["status"] in ACTIVE_STATES and now - created_at(instance) >= self._config.idle_timeout_seconds:
                    vm_runners = runners.get(name, [])
                    if not vm_runners:
                        # Never registered, or its job ended and the VM did not power off.
                        self._compute.delete(instance)
                        removed.add(name)
                        summary["idle"] += 1
                    elif not any(r["busy"] for r in vm_runners) and all(
                        self._github.delete_runner(r["id"]) for r in vm_runners
                    ):
                        self._compute.delete(instance)
                        removed.add(name)
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
                if now - runner["registered_at"] < ORPHAN_GRACE_SECONDS:
                    continue
                try:
                    # Check again: the webhook may have just created this VM.
                    if self._compute.find(vm) is None and self._github.delete_runner(runner["id"]):
                        summary["orphan_runners"] += 1
                except Exception as exc:
                    summary["errors"] += 1
                    log.error("reconcile failed for runner", runner=runner["name"], detail=str(exc))

        # Zones with no capacity stop all starts.
        live = [i for i in instances if i["name"] not in removed]
        for job, pool, name in self._jobs_without_a_runner(now, live, runners):
            if summary["started"] >= RECONCILE_MAX_STARTS:
                break
            # The webhook made attempt 0. Each reconcile pass since then is one
            # more attempt, so retries move through the zones.
            attempt = max(1, int((now - parse_timestamp(job["created_at"])) // RECONCILE_INTERVAL_SECONDS))
            try:
                result = self.start_runner(
                    int(job["id"]),
                    self._monotonic(),
                    attempt,
                    job_labels=job.get("labels", []),
                    name=name,
                    wait_for_start=False,
                )
            except Exception as exc:
                summary["errors"] += 1
                log.error("reconcile failed to start a runner", job_id=job["id"], detail=str(exc))
                continue
            if result is StartResult.CREATED:
                summary["started"] += 1
            elif result is StartResult.NO_CAPACITY:
                break

        log.info("reconcile pass", **summary)
        return summary

    def _jobs_without_a_runner(
        self,
        now: float,
        instances: list[dict[str, Any]],
        runners: Mapping[str, list[dict[str, Any]]],
    ) -> list[tuple[dict[str, Any], RunnerPool, str]]:
        """Queued jobs that no VM will take, oldest first, each with its pool and the VM name to start.

        GitHub hands a new runner any queued job with its labels, not the job
        its VM is named after. So the VMs of a pool are interchangeable: each
        one whose runner is not busy yet takes one queued job of that pool. A
        job whose own VM took another job needs a VM under another name.
        """
        vm_names = {instance["name"] for instance in instances}
        spare: dict[str, set[str]] = {}
        for instance in instances:
            if instance["status"] in ACTIVE_STATES and not any(r["busy"] for r in runners.get(instance["name"], [])):
                spare.setdefault(vm_class(instance), set()).add(instance["name"])

        waiting: list[tuple[dict[str, Any], RunnerPool]] = []
        for job in sorted(self._queued_jobs(), key=lambda queued: parse_timestamp(queued["created_at"])):
            pool = pool_for(self._config, job.get("labels", []))
            if pool is None:
                continue
            own = self.vm_name(int(job["id"]))
            young = now - parse_timestamp(job["created_at"]) < QUEUE_GRACE_SECONDS
            if own in spare.get(pool.name, set()):
                # Its own VM is still free, and will take this job or another.
                spare[pool.name].discard(own)
            elif young and own not in vm_names:
                # Its webhook may be creating its VM right now.
                continue
            else:
                waiting.append((job, pool))

        result = []
        for job, pool in waiting:
            pool_spare = spare.get(pool.name, set())
            if pool_spare:
                pool_spare.pop()
                continue
            if now - parse_timestamp(job["created_at"]) < QUEUE_GRACE_SECONDS:
                continue
            result.append((job, pool, self._free_vm_name(int(job["id"]), vm_names)))
        return result

    def _free_vm_name(self, job_id: int, vm_names: set[str]) -> str:
        """The job's own VM name, or the next numbered one when a VM has it."""
        name = self.vm_name(job_id)
        number = 2
        while name in vm_names:
            name = f"{self.vm_name(job_id)}-{number}"
            number += 1
        return name

    def _queued_jobs(self) -> list[dict[str, Any]]:
        """Queued jobs our runners can take, from the private repositories."""
        queued = []
        for repository in self._config.repositories:
            try:
                # The same rule as the webhook: never start a VM for a public repository.
                if self._github.repository(repository).get("private") is not True:
                    log.warning("skipped a public repository", repository=repository)
                    continue
                jobs = self._github.queued_jobs(repository)
            except Exception as exc:
                log.error("could not list queued jobs", repository=repository, detail=str(exc))
                continue
            queued.extend(job for job in jobs if wants_runner(self._config, job.get("labels", [])))
        return queued
