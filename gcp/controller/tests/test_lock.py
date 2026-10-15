from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import pytest

from ghr.lock import API_URL, UPLOAD_URL, GcsLock, LockError, LockTimeout

OBJECT_URL = f"{API_URL}/b/locks/o/ghr%2Fstart-runner"
NOW = 1_800_000_000.0


@dataclass
class FakeResponse:
    status_code: int
    payload: Any = None
    text: str = ""

    def json(self) -> Any:
        return self.payload


@dataclass
class FakeSession:
    uploads: list[FakeResponse]
    reads: list[FakeResponse] = field(default_factory=list)
    deletes: list[FakeResponse] = field(default_factory=lambda: [FakeResponse(204)])
    calls: list[tuple[str, str, dict[str, Any]]] = field(default_factory=list)

    @staticmethod
    def _next(queue: list[FakeResponse]) -> FakeResponse:
        return queue.pop(0) if len(queue) > 1 else queue[0]

    def post(self, url: str, **kwargs: Any) -> FakeResponse:
        self.calls.append(("POST", url, kwargs))
        return self._next(self.uploads)

    def get(self, url: str, **kwargs: Any) -> FakeResponse:
        self.calls.append(("GET", url, kwargs))
        return self._next(self.reads)

    def delete(self, url: str, **kwargs: Any) -> FakeResponse:
        self.calls.append(("DELETE", url, kwargs))
        return self._next(self.deletes)


def created(age_seconds: float, generation: str = "7") -> FakeResponse:
    from datetime import datetime, timezone

    time_created = datetime.fromtimestamp(NOW - age_seconds, tz=timezone.utc).isoformat().replace("+00:00", "Z")
    return FakeResponse(200, {"timeCreated": time_created, "generation": generation})


def make_lock(session: FakeSession) -> tuple[GcsLock, list[float]]:
    now = [0.0]

    def sleep(seconds: float) -> None:
        now[0] += seconds

    lock = GcsLock("locks", "ghr/start-runner", session=session, clock=lambda: NOW, monotonic=lambda: now[0], sleep=sleep)  # type: ignore[arg-type]
    return lock, now


def test_takes_and_releases_the_lock() -> None:
    session = FakeSession(uploads=[FakeResponse(200, {"generation": "42"})])
    lock, _ = make_lock(session)
    with lock.held(deadline=5):
        pass

    method, url, kwargs = session.calls[0]
    assert (method, url) == ("POST", f"{UPLOAD_URL}/b/locks/o")
    assert kwargs["params"]["ifGenerationMatch"] == "0" and kwargs["params"]["name"] == "ghr/start-runner"
    assert session.calls[-1][:2] == ("DELETE", OBJECT_URL)
    assert session.calls[-1][2]["params"] == {"ifGenerationMatch": "42"}


def test_releases_the_lock_when_the_block_fails() -> None:
    session = FakeSession(uploads=[FakeResponse(200, {"generation": "42"})])
    lock, _ = make_lock(session)
    with pytest.raises(RuntimeError), lock.held(deadline=5):
        raise RuntimeError("boom")
    assert session.calls[-1][0] == "DELETE"


def test_waits_while_another_holder_has_the_lock() -> None:
    session = FakeSession(
        uploads=[FakeResponse(412), FakeResponse(412), FakeResponse(200, {"generation": "43"})],
        reads=[created(age_seconds=1)],
    )
    lock, now = make_lock(session)
    with lock.held(deadline=5):
        pass
    assert now[0] == pytest.approx(0.4)
    assert [c[0] for c in session.calls].count("DELETE") == 1  # only its own release


def test_times_out_while_the_lock_stays_held() -> None:
    session = FakeSession(uploads=[FakeResponse(412)], reads=[created(age_seconds=1)])
    lock, _ = make_lock(session)
    with pytest.raises(LockTimeout), lock.held(deadline=1):
        pass


def test_removes_a_stale_lock_and_takes_it() -> None:
    session = FakeSession(
        uploads=[FakeResponse(412), FakeResponse(200, {"generation": "44"})],
        reads=[created(age_seconds=60, generation="7")],
    )
    lock, _ = make_lock(session)
    with lock.held(deadline=5):
        pass
    deletes = [c for c in session.calls if c[0] == "DELETE"]
    assert [d[2]["params"]["ifGenerationMatch"] for d in deletes] == ["7", "44"]


def test_retries_when_the_lock_disappears_between_calls() -> None:
    session = FakeSession(
        uploads=[FakeResponse(412), FakeResponse(200, {"generation": "45"})],
        reads=[FakeResponse(404)],
    )
    lock, _ = make_lock(session)
    with lock.held(deadline=5):
        pass


@pytest.mark.parametrize(
    "session",
    [
        FakeSession(uploads=[FakeResponse(403, text="denied")]),
        FakeSession(uploads=[FakeResponse(412)], reads=[FakeResponse(500, text="oops")]),
    ],
)
def test_raises_on_unexpected_errors(session: FakeSession) -> None:
    lock, _ = make_lock(session)
    with pytest.raises(LockError), lock.held(deadline=5):
        pass


def test_release_tolerates_a_lock_already_removed_but_raises_other_errors() -> None:
    for status in (404, 412):
        lock, _ = make_lock(FakeSession(uploads=[FakeResponse(200, {"generation": "1"})], deletes=[FakeResponse(status)]))
        with lock.held(deadline=5):
            pass
    lock, _ = make_lock(FakeSession(uploads=[FakeResponse(200, {"generation": "1"})], deletes=[FakeResponse(500)]))
    with pytest.raises(LockError), lock.held(deadline=5):
        pass


def test_uses_application_default_credentials_without_a_session(monkeypatch: pytest.MonkeyPatch) -> None:
    import ghr.lock as lock_module

    monkeypatch.setattr(lock_module.google.auth, "default", lambda scopes: ("credentials", "project"))
    monkeypatch.setattr(lock_module, "AuthorizedSession", lambda credentials: f"session for {credentials}")
    assert GcsLock("locks", "name")._session == "session for credentials"
