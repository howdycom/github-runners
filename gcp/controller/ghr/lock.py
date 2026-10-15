"""A mutex shared by all function instances, held as one object in GCS."""

from __future__ import annotations

import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from datetime import datetime
from typing import Any
from urllib.parse import quote

import google.auth
import requests
from google.auth.transport.requests import AuthorizedSession

API_URL = "https://storage.googleapis.com/storage/v1"
UPLOAD_URL = "https://storage.googleapis.com/upload/storage/v1"
SCOPES = ("https://www.googleapis.com/auth/devstorage.read_write",)
REQUEST_TIMEOUT_SECONDS = 10
RETRY_SECONDS = 0.2
# A holder that crashed leaves its object behind. The critical section takes
# about a second, so an older object is stale.
STALE_AFTER_SECONDS = 30


class LockError(Exception):
    pass


class LockTimeout(LockError):
    pass


class GcsLock:
    """Creating an object with ifGenerationMatch=0 succeeds for one caller only."""

    def __init__(
        self,
        bucket: str,
        name: str,
        session: requests.Session | None = None,
        clock: Callable[[], float] = time.time,
        monotonic: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._bucket = bucket
        self._name = name
        if session is None:
            credentials, _ = google.auth.default(scopes=SCOPES)
            session = AuthorizedSession(credentials)
        self._session = session
        self._clock = clock
        self._monotonic = monotonic
        self._sleep = sleep

    @contextmanager
    def held(self, deadline: float) -> Iterator[None]:
        """Holds the lock for the block. Raises LockTimeout after the deadline (monotonic)."""
        generation = self._acquire(deadline)
        try:
            yield
        finally:
            self._delete(generation)

    def _acquire(self, deadline: float) -> str:
        while True:
            response = self._session.post(
                f"{UPLOAD_URL}/b/{self._bucket}/o",
                params={"uploadType": "media", "name": self._name, "ifGenerationMatch": "0"},
                data=str(self._clock()).encode(),
                headers={"Content-Type": "text/plain"},
                timeout=REQUEST_TIMEOUT_SECONDS,
            )
            if response.status_code == 200:
                return str(response.json()["generation"])
            if response.status_code != 412:
                raise LockError(f"acquire failed: HTTP {response.status_code}: {response.text[:300]}")
            if self._remove_if_stale():
                continue
            if self._monotonic() >= deadline:
                raise LockTimeout(f"lock {self._name} still held at the deadline")
            self._sleep(RETRY_SECONDS)

    def _remove_if_stale(self) -> bool:
        response = self._session.get(f"{API_URL}/b/{self._bucket}/o/{self._object_path()}", timeout=REQUEST_TIMEOUT_SECONDS)
        if response.status_code == 404:
            return True
        if response.status_code >= 400:
            raise LockError(f"read failed: HTTP {response.status_code}: {response.text[:300]}")
        metadata: dict[str, Any] = response.json()
        created = datetime.fromisoformat(metadata["timeCreated"].replace("Z", "+00:00")).timestamp()
        if self._clock() - created < STALE_AFTER_SECONDS:
            return False
        self._delete(str(metadata["generation"]))
        return True

    def _delete(self, generation: str) -> None:
        # The generation precondition makes sure only this holder's object is
        # deleted, never one a later holder created.
        response = self._session.delete(
            f"{API_URL}/b/{self._bucket}/o/{self._object_path()}",
            params={"ifGenerationMatch": generation},
            timeout=REQUEST_TIMEOUT_SECONDS,
        )
        if response.status_code not in (204, 404, 412):
            raise LockError(f"release failed: HTTP {response.status_code}: {response.text[:300]}")

    def _object_path(self) -> str:
        return quote(self._name, safe="")
