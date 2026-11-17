"""Compute Engine side: create, find and delete runner VMs."""

from __future__ import annotations

import re
import time
from collections.abc import Callable, Iterator
from typing import Any

import google.auth
import requests
from google.auth.transport.requests import AuthorizedSession

from .timestamps import parse_timestamp

API_URL = "https://compute.googleapis.com/compute/v1"
SCOPES = ("https://www.googleapis.com/auth/cloud-platform",)
REQUEST_TIMEOUT_SECONDS = 15
OPERATION_POLL_SECONDS = 1.0

# Operation errors meaning "this zone has no capacity right now"; the next
# zone may have some.
ZONE_CAPACITY_ERRORS = frozenset({"ZONE_RESOURCE_POOL_EXHAUSTED", "ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS"})

# States in which a VM runs or will run a job.
ACTIVE_STATES = frozenset({"PROVISIONING", "STAGING", "RUNNING"})
# States after the VM powered off or was stopped; it will not run a job again.
FINISHED_STATES = frozenset({"STOPPING", "STOPPED", "SUSPENDING", "SUSPENDED", "TERMINATED"})

MANAGED_LABEL = "ghr_managed"
POOL_LABEL = "ghr_pool"
REPO_LABEL = "ghr_repo"
JOB_LABEL = "ghr_job"
# Compute Engine label values: lowercase letters, digits, "_" and "-", at most 63 characters.
LABEL_VALUE_MAX = 63


def label_value(text: str | None) -> str:
    """A label value for free text such as a job name. Empty when nothing usable is left."""
    cleaned = re.sub(r"[^a-z0-9_-]+", "-", (text or "").lower())
    return re.sub(r"-{2,}", "-", cleaned).strip("-")[:LABEL_VALUE_MAX].strip("-")


def cost_labels(repository: str | None, job_name: str | None) -> dict[str, str]:
    """The labels that let the billing export split cost by repository and by job.

    The repository is its name without the owner. A label with no usable
    value is left out, because Compute Engine would otherwise store an empty one.
    """
    labels = {
        REPO_LABEL: label_value((repository or "").rsplit("/", 1)[-1]),
        JOB_LABEL: label_value(job_name),
    }
    return {key: value for key, value in labels.items() if value}


class ComputeError(Exception):
    pass


class AlreadyExists(ComputeError):
    pass


class ZoneUnavailable(ComputeError):
    pass


class Compute:
    def __init__(
        self,
        project: str,
        pool: str,
        session: requests.Session | None = None,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._project = project
        self._pool = pool
        if session is None:
            credentials, _ = google.auth.default(scopes=SCOPES)
            session = AuthorizedSession(credentials)
        self._session = session
        self._clock = clock
        self._sleep = sleep
        self._templates: dict[str, dict[str, Any]] = {}

    def list_instances(self) -> list[dict[str, Any]]:
        """All VMs of this runner pool, in every zone."""
        return list(self._aggregated(f'(labels.{MANAGED_LABEL} = "true") (labels.{POOL_LABEL} = "{self._pool}")'))

    def find(self, name: str) -> dict[str, Any] | None:
        for instance in self._aggregated(f'(name = "{name}") (labels.{POOL_LABEL} = "{self._pool}")'):
            return instance
        return None

    def insert(
        self,
        zone: str,
        name: str,
        template: str,
        metadata: dict[str, str],
        labels: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        """Sends the request that creates a VM from the template, and returns its operation.

        Raises AlreadyExists. The VM is listed as soon as this returns, so the
        caller's next count includes it. Pass the operation to wait().
        """
        properties = self._template(template)["properties"]
        items = {item["key"]: item["value"] for item in properties.get("metadata", {}).get("items", [])}
        items.update(metadata)
        body = {
            "name": name,
            # Sent in full, so the result never depends on how Compute Engine
            # merges request metadata with template metadata.
            "metadata": {"items": [{"key": key, "value": value} for key, value in items.items()]},
            "labels": {**properties.get("labels", {}), **(labels or {}), MANAGED_LABEL: "true", POOL_LABEL: self._pool},
        }
        response = self._session.post(
            f"{API_URL}/projects/{self._project}/zones/{zone}/instances",
            params={"sourceInstanceTemplate": template},
            json=body,
            timeout=REQUEST_TIMEOUT_SECONDS,
        )
        if response.status_code == 409:
            raise AlreadyExists(name)
        _raise_for_status(response, f"create {name} in {zone}")
        return response.json()

    def delete(self, instance: dict[str, Any]) -> None:
        response = self._session.delete(
            f"{API_URL}/projects/{self._project}/zones/{zone_of(instance)}/instances/{instance['name']}",
            timeout=REQUEST_TIMEOUT_SECONDS,
        )
        if response.status_code == 404:
            return
        _raise_for_status(response, f"delete {instance['name']}")

    def wait(self, zone: str, operation: dict[str, Any], deadline: float) -> bool:
        """Waits for a create operation until it finishes or the deadline (monotonic) passes.

        Returns True when the VM started, False when the operation was still
        running at the deadline. Raises ZoneUnavailable. A VM that fails after
        the deadline does not exist; the reconcile job then starts one for the
        still-queued job, in another zone.
        """
        while True:
            if operation.get("status") == "DONE":
                errors = operation.get("error", {}).get("errors", [])
                codes = {error.get("code") for error in errors}
                if codes & ZONE_CAPACITY_ERRORS:
                    raise ZoneUnavailable(f"{zone}: {', '.join(sorted(codes))}")
                if errors:
                    raise ComputeError(f"{zone}: {errors}")
                return True
            if self._clock() >= deadline:
                return False
            self._sleep(OPERATION_POLL_SECONDS)
            response = self._session.get(
                f"{API_URL}/projects/{self._project}/zones/{zone}/operations/{operation['name']}",
                timeout=REQUEST_TIMEOUT_SECONDS,
            )
            _raise_for_status(response, "get operation")
            operation = response.json()

    def _template(self, template: str) -> dict[str, Any]:
        if template not in self._templates:
            response = self._session.get(f"{API_URL}/{template}", timeout=REQUEST_TIMEOUT_SECONDS)
            _raise_for_status(response, f"get template {template}")
            self._templates[template] = response.json()
        return self._templates[template]

    def _aggregated(self, filter_expression: str) -> Iterator[dict[str, Any]]:
        params: dict[str, Any] = {"filter": filter_expression, "returnPartialSuccess": "true", "maxResults": 500}
        while True:
            response = self._session.get(
                f"{API_URL}/projects/{self._project}/aggregated/instances",
                params=params,
                timeout=REQUEST_TIMEOUT_SECONDS,
            )
            _raise_for_status(response, "list instances")
            payload = response.json()
            for scoped in payload.get("items", {}).values():
                yield from scoped.get("instances", [])
            token = payload.get("nextPageToken")
            if not token:
                return
            params = {**params, "pageToken": token}


def zone_of(instance: dict[str, Any]) -> str:
    return instance["zone"].rsplit("/", 1)[-1]


def created_at(instance: dict[str, Any]) -> float:
    return parse_timestamp(instance["creationTimestamp"])


def _raise_for_status(response: requests.Response, action: str) -> None:
    if response.status_code >= 400:
        raise ComputeError(f"{action} failed: HTTP {response.status_code}: {response.text[:300]}")
