"""GitHub side: webhook signatures, GitHub App auth and the runner APIs."""

from __future__ import annotations

import hashlib
import hmac
import time
from collections.abc import Callable, Iterator
from datetime import datetime
from typing import Any

import jwt
import requests

API_URL = "https://api.github.com"
API_VERSION = "2022-11-28"
REQUEST_TIMEOUT_SECONDS = 10
# Renew the installation token this long before GitHub expires it (1 hour).
TOKEN_REFRESH_MARGIN_SECONDS = 300
# The App JWT may live at most 10 minutes; backdate iat for clock skew.
APP_JWT_LIFETIME_SECONDS = 540
APP_JWT_BACKDATE_SECONDS = 60
PAGE_SIZE = 100


class GitHubError(Exception):
    pass


class RunnerNameTaken(GitHubError):
    """A runner with this name is already registered."""


def verify_signature(secret: bytes, body: bytes, signature_header: str | None) -> bool:
    """Checks GitHub's X-Hub-Signature-256 header in constant time."""
    if not secret or not signature_header or not signature_header.startswith("sha256="):
        return False
    expected = "sha256=" + hmac.new(secret, body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature_header)


class GitHubApp:
    """Authenticates as one installation of a GitHub App."""

    def __init__(
        self,
        app_id: str,
        installation_id: int,
        private_key: str,
        session: requests.Session | None = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._app_id = app_id
        self._installation_id = installation_id
        self._private_key = private_key
        self._session = session or requests.Session()
        self._clock = clock
        self._token: str | None = None
        self._token_expires_at = 0.0

    def _app_jwt(self) -> str:
        now = int(self._clock())
        claims = {
            "iat": now - APP_JWT_BACKDATE_SECONDS,
            "exp": now + APP_JWT_LIFETIME_SECONDS,
            "iss": self._app_id,
        }
        return jwt.encode(claims, self._private_key, algorithm="RS256")

    def _installation_token(self) -> str:
        if self._token and self._clock() < self._token_expires_at - TOKEN_REFRESH_MARGIN_SECONDS:
            return self._token
        response = self._session.post(
            f"{API_URL}/app/installations/{self._installation_id}/access_tokens",
            headers={**_base_headers(), "Authorization": f"Bearer {self._app_jwt()}"},
            timeout=REQUEST_TIMEOUT_SECONDS,
        )
        _raise_for_status(response, "create installation token")
        payload = response.json()
        self._token = payload["token"]
        self._token_expires_at = _parse_timestamp(payload["expires_at"])
        return self._token

    def request(self, method: str, path: str, **kwargs: Any) -> requests.Response:
        headers = {**_base_headers(), "Authorization": f"Bearer {self._installation_token()}"}
        return self._session.request(method, f"{API_URL}{path}", headers=headers, timeout=REQUEST_TIMEOUT_SECONDS, **kwargs)


class GitHubClient:
    """The organization-level calls the controller needs."""

    def __init__(self, app: GitHubApp, org: str) -> None:
        self._app = app
        self._org = org

    def runner_group(self, name: str) -> dict[str, Any]:
        for group in self._paginate(f"/orgs/{self._org}/actions/runner-groups", "runner_groups"):
            if group["name"].lower() == name.lower():
                return group
        raise GitHubError(f"runner group {name!r} not found in {self._org}")

    def generate_jit_config(self, name: str, runner_group_id: int, labels: tuple[str, ...]) -> tuple[int, str]:
        response = self._app.request(
            "POST",
            f"/orgs/{self._org}/actions/runners/generate-jitconfig",
            json={"name": name, "runner_group_id": runner_group_id, "labels": list(labels)},
        )
        if response.status_code == 409:
            raise RunnerNameTaken(name)
        _raise_for_status(response, "generate jit config")
        payload = response.json()
        return int(payload["runner"]["id"]), payload["encoded_jit_config"]

    def list_runners(self, name_prefix: str) -> list[dict[str, Any]]:
        return [
            runner
            for runner in self._paginate(f"/orgs/{self._org}/actions/runners", "runners")
            if runner["name"].startswith(name_prefix)
        ]

    def delete_runner(self, runner_id: int) -> bool:
        """Deregisters a runner. Returns False if GitHub refused (422)."""
        response = self._app.request("DELETE", f"/orgs/{self._org}/actions/runners/{runner_id}")
        if response.status_code in (204, 404):
            return True
        if response.status_code == 422:
            return False
        _raise_for_status(response, "delete runner")
        return True

    def repository(self, name: str) -> dict[str, Any]:
        response = self._app.request("GET", f"/repos/{self._org}/{name}")
        _raise_for_status(response, "get repository")
        return response.json()

    def queued_jobs(self, repository: str) -> list[dict[str, Any]]:
        """Queued jobs of one repository, including those in runs already in progress."""
        jobs: list[dict[str, Any]] = []
        for status in ("queued", "in_progress"):
            response = self._app.request(
                "GET",
                f"/repos/{self._org}/{repository}/actions/runs",
                params={"status": status, "per_page": PAGE_SIZE},
            )
            _raise_for_status(response, "list workflow runs")
            for run in response.json()["workflow_runs"]:
                for job in self._paginate(
                    f"/repos/{self._org}/{repository}/actions/runs/{run['id']}/jobs",
                    "jobs",
                    {"filter": "latest"},
                ):
                    if job["status"] == "queued":
                        jobs.append(job)
        return jobs

    def _paginate(self, path: str, key: str, params: dict[str, Any] | None = None) -> Iterator[dict[str, Any]]:
        page = 1
        while True:
            response = self._app.request("GET", path, params={**(params or {}), "per_page": PAGE_SIZE, "page": page})
            _raise_for_status(response, f"list {key}")
            items = response.json()[key]
            yield from items
            if len(items) < PAGE_SIZE:
                return
            page += 1


def _base_headers() -> dict[str, str]:
    return {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": API_VERSION}


def _raise_for_status(response: requests.Response, action: str) -> None:
    if response.status_code >= 400:
        raise GitHubError(f"{action} failed: HTTP {response.status_code}: {response.text[:300]}")


def _parse_timestamp(value: str) -> float:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
