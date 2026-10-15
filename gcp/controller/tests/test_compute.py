from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import pytest

from ghr.compute import AlreadyExists, Compute, ComputeError, ZoneUnavailable, created_at, zone_of

API = "https://compute.googleapis.com/compute/v1"
TEMPLATE = "projects/p/global/instanceTemplates/ghr-runner-1"


@dataclass
class FakeResponse:
    status_code: int
    payload: Any = None
    text: str = ""

    def json(self) -> Any:
        return self.payload


@dataclass
class FakeSession:
    get_responses: dict[str, list[FakeResponse]] = field(default_factory=dict)
    post_response: FakeResponse = field(default_factory=lambda: FakeResponse(200, {"name": "op-1", "status": "DONE"}))
    delete_response: FakeResponse = field(default_factory=lambda: FakeResponse(200, {}))
    calls: list[tuple[str, str, dict[str, Any]]] = field(default_factory=list)

    def get(self, url: str, **kwargs: Any) -> FakeResponse:
        self.calls.append(("GET", url, kwargs))
        queue = self.get_responses[url]
        return queue.pop(0) if len(queue) > 1 else queue[0]

    def post(self, url: str, **kwargs: Any) -> FakeResponse:
        self.calls.append(("POST", url, kwargs))
        return self.post_response

    def delete(self, url: str, **kwargs: Any) -> FakeResponse:
        self.calls.append(("DELETE", url, kwargs))
        return self.delete_response


def template_response() -> FakeResponse:
    return FakeResponse(
        200,
        {
            "properties": {
                "metadata": {"items": [{"key": "startup-script", "value": "#!/bin/bash"}, {"key": "runner-version", "value": "2.337.0"}]},
                "labels": {"ghr_managed": "true", "ghr_pool": "ghr"},
            }
        },
    )


def make_compute(session: FakeSession, clock: list[float] | None = None) -> Compute:
    now = clock or [0.0]

    def sleep(seconds: float) -> None:
        now[0] += seconds

    return Compute("p", "ghr", session=session, clock=lambda: now[0], sleep=sleep)  # type: ignore[arg-type]


def test_insert_sends_template_metadata_plus_the_jit_config() -> None:
    session = FakeSession(get_responses={f"{API}/{TEMPLATE}": [template_response()]})
    make_compute(session).insert("zone-a", "ghr-1", TEMPLATE, {"jit-config": "abc"}, deadline=10)

    method, url, kwargs = next(c for c in session.calls if c[0] == "POST")
    assert url == f"{API}/projects/p/zones/zone-a/instances"
    assert kwargs["params"] == {"sourceInstanceTemplate": TEMPLATE}
    items = {i["key"]: i["value"] for i in kwargs["json"]["metadata"]["items"]}
    assert items == {"startup-script": "#!/bin/bash", "runner-version": "2.337.0", "jit-config": "abc"}
    assert kwargs["json"]["labels"] == {"ghr_managed": "true", "ghr_pool": "ghr"}


def test_insert_already_exists() -> None:
    session = FakeSession(get_responses={f"{API}/{TEMPLATE}": [template_response()]}, post_response=FakeResponse(409))
    with pytest.raises(AlreadyExists):
        make_compute(session).insert("zone-a", "ghr-1", TEMPLATE, {}, deadline=10)


def test_insert_reports_a_zone_without_capacity() -> None:
    op_url = f"{API}/projects/p/zones/zone-a/operations/op-1"
    session = FakeSession(
        get_responses={
            f"{API}/{TEMPLATE}": [template_response()],
            op_url: [FakeResponse(200, {"name": "op-1", "status": "DONE", "error": {"errors": [{"code": "ZONE_RESOURCE_POOL_EXHAUSTED"}]}})],
        },
        post_response=FakeResponse(200, {"name": "op-1", "status": "RUNNING"}),
    )
    with pytest.raises(ZoneUnavailable):
        make_compute(session).insert("zone-a", "ghr-1", TEMPLATE, {}, deadline=10)


def test_insert_raises_other_operation_errors() -> None:
    session = FakeSession(
        get_responses={f"{API}/{TEMPLATE}": [template_response()]},
        post_response=FakeResponse(200, {"name": "op-1", "status": "DONE", "error": {"errors": [{"code": "QUOTA_EXCEEDED"}]}}),
    )
    with pytest.raises(ComputeError) as exc:
        make_compute(session).insert("zone-a", "ghr-1", TEMPLATE, {}, deadline=10)
    assert not isinstance(exc.value, ZoneUnavailable)


def test_insert_returns_when_the_deadline_passes() -> None:
    op_url = f"{API}/projects/p/zones/zone-a/operations/op-1"
    session = FakeSession(
        get_responses={f"{API}/{TEMPLATE}": [template_response()], op_url: [FakeResponse(200, {"name": "op-1", "status": "RUNNING"})]},
        post_response=FakeResponse(200, {"name": "op-1", "status": "RUNNING"}),
    )
    make_compute(session).insert("zone-a", "ghr-1", TEMPLATE, {}, deadline=3)
    assert sum(1 for c in session.calls if c[1] == op_url) == 3


def test_template_is_fetched_once() -> None:
    session = FakeSession(get_responses={f"{API}/{TEMPLATE}": [template_response()]})
    compute = make_compute(session)
    compute.insert("zone-a", "ghr-1", TEMPLATE, {}, deadline=10)
    compute.insert("zone-a", "ghr-2", TEMPLATE, {}, deadline=10)
    assert sum(1 for c in session.calls if c[1].endswith(TEMPLATE)) == 1


def test_list_instances_filters_on_pool_labels_and_paginates() -> None:
    url = f"{API}/projects/p/aggregated/instances"
    session = FakeSession(
        get_responses={
            url: [
                FakeResponse(200, {"items": {"zones/zone-a": {"instances": [{"name": "ghr-1"}]}, "zones/zone-b": {}}, "nextPageToken": "t"}),
                FakeResponse(200, {"items": {"zones/zone-b": {"instances": [{"name": "ghr-2"}]}}}),
            ]
        }
    )
    names = [i["name"] for i in make_compute(session).list_instances()]
    assert names == ["ghr-1", "ghr-2"]
    first, second = (c[2]["params"] for c in session.calls)
    assert first["filter"] == '(labels.ghr_managed = "true") (labels.ghr_pool = "ghr")'
    assert second["pageToken"] == "t"


def test_delete_ignores_missing_vms() -> None:
    session = FakeSession(delete_response=FakeResponse(404))
    make_compute(session).delete({"name": "ghr-1", "zone": "https://x/zones/zone-a"})
    assert session.calls[0][1] == f"{API}/projects/p/zones/zone-a/instances/ghr-1"


def test_delete_raises_on_error() -> None:
    session = FakeSession(delete_response=FakeResponse(403, text="denied"))
    with pytest.raises(ComputeError):
        make_compute(session).delete({"name": "ghr-1", "zone": "https://x/zones/zone-a"})


def test_instance_helpers() -> None:
    instance = {"zone": "https://www.googleapis.com/compute/v1/projects/p/zones/us-central1-a", "creationTimestamp": "2027-01-15T00:00:00.000-08:00"}
    assert zone_of(instance) == "us-central1-a"
    assert created_at(instance) == 1_800_000_000.0
