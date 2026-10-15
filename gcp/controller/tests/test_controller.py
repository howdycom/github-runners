from __future__ import annotations

import json

import pytest
from conftest import NOW, SECRET, FakeCompute, FakeGitHub, instance, job, make_config, sign, webhook_request

from ghr.compute import ComputeError
from ghr.controller import Controller, UnsafeRunnerGroup, wants_runner, zone_order


def controller(github: FakeGitHub, compute: FakeCompute, **config: object) -> Controller:
    return Controller(make_config(**config), github, compute, clock=lambda: NOW, monotonic=lambda: 0.0)


# --- Matching ---------------------------------------------------------------


@pytest.mark.parametrize(
    ("labels", "expected"),
    [
        (["gcp-x64"], True),
        (["self-hosted", "gcp-x64"], True),
        (["Self-Hosted", "Linux", "X64", "GCP-X64"], True),
        (["ubuntu-latest"], False),
        (["self-hosted"], False),
        (["self-hosted", "gcp-x64", "gpu"], False),
    ],
)
def test_wants_runner(labels: list[str], expected: bool) -> None:
    assert wants_runner(make_config(), labels) is expected


def test_zone_order_is_stable_per_job_and_covers_every_zone() -> None:
    zones = ("a", "b", "c")
    assert zone_order(zones, 4) == ["b", "c", "a"]
    assert zone_order(zones, 4) == zone_order(zones, 4)
    assert sorted(zone_order(zones, 5)) == ["a", "b", "c"]


# --- Webhook: validation ----------------------------------------------------


def test_rejects_bad_signature(github: FakeGitHub, compute: FakeCompute) -> None:
    headers, body = webhook_request("queued", job())
    headers["X-Hub-Signature-256"] = sign(body, b"wrong")
    assert controller(github, compute).handle_webhook(headers, body, SECRET)[0] == 401
    assert compute.inserts == []


def test_rejects_missing_signature(github: FakeGitHub, compute: FakeCompute) -> None:
    headers, body = webhook_request("queued", job())
    del headers["X-Hub-Signature-256"]
    assert controller(github, compute).handle_webhook(headers, body, SECRET)[0] == 401


def test_answers_ping(github: FakeGitHub, compute: FakeCompute) -> None:
    body = b"{}"
    status, _ = controller(github, compute).handle_webhook({"X-GitHub-Event": "ping", "X-Hub-Signature-256": sign(body)}, body, SECRET)
    assert status == 200


def test_rejects_other_installation(github: FakeGitHub, compute: FakeCompute) -> None:
    headers, body = webhook_request("queued", job(), installation={"id": 999})
    assert controller(github, compute).handle_webhook(headers, body, SECRET)[0] == 403


def test_rejects_other_organization(github: FakeGitHub, compute: FakeCompute) -> None:
    headers, body = webhook_request("queued", job(), organization={"login": "someone-else"})
    assert controller(github, compute).handle_webhook(headers, body, SECRET)[0] == 403


def test_ignores_jobs_for_other_labels(github: FakeGitHub, compute: FakeCompute) -> None:
    headers, body = webhook_request("queued", job(labels=("ubuntu-latest",)))
    assert controller(github, compute).handle_webhook(headers, body, SECRET)[0] == 202
    assert compute.inserts == []


def test_ignores_jobs_from_public_repositories(github: FakeGitHub, compute: FakeCompute) -> None:
    headers, body = webhook_request("queued", job(), private=False)
    status, response = controller(github, compute).handle_webhook(headers, body, SECRET)
    assert (status, response["reason"]) == (202, "public repository")
    assert compute.inserts == [] and github.jit_calls == []


# --- Webhook: queued ----------------------------------------------------------


def test_queued_job_creates_one_vm_with_a_jit_config(github: FakeGitHub, compute: FakeCompute) -> None:
    headers, body = webhook_request("queued", job(1001))
    status, response = controller(github, compute).handle_webhook(headers, body, SECRET)

    assert (status, response) == (200, {"result": "created"})
    assert github.jit_calls == [("ghr-1001", 7, ("self-hosted", "linux", "x64", "gcp-x64"))]
    zone, name, metadata = compute.inserts[0]
    assert (name, metadata) == ("ghr-1001", {"jit-config": "jit-ghr-1001"})
    assert zone == zone_order(("zone-a", "zone-b", "zone-c"), 1001)[0]


def test_duplicate_delivery_does_not_create_a_second_vm(github: FakeGitHub, compute: FakeCompute) -> None:
    ctrl = controller(github, compute)
    headers, body = webhook_request("queued", job(1001))
    ctrl.handle_webhook(headers, body, SECRET)
    status, response = ctrl.handle_webhook(headers, body, SECRET)

    assert response == {"result": "exists"}
    assert len(compute.inserts) == 1 and len(github.jit_calls) == 1


def test_falls_back_to_the_next_zone_without_capacity(github: FakeGitHub, compute: FakeCompute) -> None:
    first = zone_order(("zone-a", "zone-b", "zone-c"), 1001)[0]
    compute.full_zones = {first}
    headers, body = webhook_request("queued", job(1001))
    _, response = controller(github, compute).handle_webhook(headers, body, SECRET)

    assert response == {"result": "created"}
    assert [z for z, _, _ in compute.inserts][:2] == zone_order(("zone-a", "zone-b", "zone-c"), 1001)[:2]


def test_no_capacity_anywhere_removes_the_runner_registration(github: FakeGitHub, compute: FakeCompute) -> None:
    compute.full_zones = {"zone-a", "zone-b", "zone-c"}
    _, response = controller(github, compute).handle_webhook(*webhook_request("queued", job(1001)), SECRET)

    assert response == {"result": "no capacity"}
    assert len(compute.inserts) == 3
    assert github.runners == {}


def test_insert_error_removes_the_runner_registration_and_fails(github: FakeGitHub, compute: FakeCompute) -> None:
    compute.fail_insert = ComputeError("quota exceeded")
    with pytest.raises(ComputeError):
        controller(github, compute).handle_webhook(*webhook_request("queued", job(1001)), SECRET)
    assert github.runners == {}


def test_concurrent_creation_keeps_one_runner(github: FakeGitHub, compute: FakeCompute) -> None:
    compute.race_on_insert = True
    _, response = controller(github, compute).handle_webhook(*webhook_request("queued", job(1001)), SECRET)
    assert response == {"result": "exists"}
    assert github.runners == {}


def test_respects_max_vms(github: FakeGitHub, compute: FakeCompute) -> None:
    compute.instances = {f"ghr-{i}": instance(f"ghr-{i}") for i in range(2)}
    _, response = controller(github, compute, max_vms=2).handle_webhook(*webhook_request("queued", job(1001)), SECRET)
    assert response == {"result": "at capacity"}
    assert github.jit_calls == []


def test_finished_vms_do_not_count_toward_max_vms(github: FakeGitHub, compute: FakeCompute) -> None:
    compute.instances = {f"ghr-{i}": instance(f"ghr-{i}", "TERMINATED") for i in range(2)}
    _, response = controller(github, compute, max_vms=2).handle_webhook(*webhook_request("queued", job(1001)), SECRET)
    assert response == {"result": "created"}


def test_refuses_a_runner_group_open_to_public_repositories(github: FakeGitHub, compute: FakeCompute) -> None:
    github.group["allows_public_repositories"] = True
    with pytest.raises(UnsafeRunnerGroup):
        controller(github, compute).handle_webhook(*webhook_request("queued", job(1001)), SECRET)
    assert compute.inserts == [] and github.jit_calls == []


def test_replaces_a_stale_runner_registration_with_the_same_name(github: FakeGitHub, compute: FakeCompute) -> None:
    github.runners["ghr-1001"] = {"id": 1, "name": "ghr-1001", "busy": False, "status": "offline"}
    _, response = controller(github, compute).handle_webhook(*webhook_request("queued", job(1001)), SECRET)
    assert response == {"result": "created"}
    assert 1 in github.deleted and github.runners["ghr-1001"]["id"] != 1


# --- Webhook: completed -------------------------------------------------------


def test_completed_job_deletes_its_vm(github: FakeGitHub, compute: FakeCompute) -> None:
    compute.instances["ghr-2002"] = instance("ghr-2002")
    _, response = controller(github, compute).handle_webhook(
        *webhook_request("completed", job(1001, runner_name="ghr-2002")), SECRET
    )
    assert response == {"result": "deleted"}
    assert compute.deleted == ["ghr-2002"]


def test_completed_job_on_another_runner_is_ignored(github: FakeGitHub, compute: FakeCompute) -> None:
    compute.instances["ghr-1001"] = instance("ghr-1001")
    status, _ = controller(github, compute).handle_webhook(
        *webhook_request("completed", job(1001, runner_name="other-runner-1")), SECRET
    )
    assert status == 202 and compute.deleted == []


def test_job_cancelled_while_queued_retires_its_idle_vm(github: FakeGitHub, compute: FakeCompute) -> None:
    compute.instances["ghr-1001"] = instance("ghr-1001")
    github.runners["ghr-1001"] = {"id": 9, "name": "ghr-1001", "busy": False, "status": "online"}
    _, response = controller(github, compute).handle_webhook(*webhook_request("completed", job(1001)), SECRET)
    assert response == {"result": "deleted"}
    assert github.deleted == [9] and compute.deleted == ["ghr-1001"]


def test_job_cancelled_while_queued_keeps_a_vm_that_took_another_job(github: FakeGitHub, compute: FakeCompute) -> None:
    compute.instances["ghr-1001"] = instance("ghr-1001")
    github.runners["ghr-1001"] = {"id": 9, "name": "ghr-1001", "busy": True, "status": "online"}
    _, response = controller(github, compute).handle_webhook(*webhook_request("completed", job(1001)), SECRET)
    assert response == {"result": "busy"}
    assert compute.deleted == []


def test_job_cancelled_while_queued_keeps_vm_when_github_refuses_removal(github: FakeGitHub, compute: FakeCompute) -> None:
    compute.instances["ghr-1001"] = instance("ghr-1001")
    github.runners["ghr-1001"] = {"id": 9, "name": "ghr-1001", "busy": False, "status": "online"}
    github.refuse_delete = {9}
    _, response = controller(github, compute).handle_webhook(*webhook_request("completed", job(1001)), SECRET)
    assert response == {"result": "busy"} and compute.deleted == []


# --- Reconcile ----------------------------------------------------------------


def test_reconcile_deletes_powered_off_vms(github: FakeGitHub, compute: FakeCompute) -> None:
    compute.instances = {"ghr-1": instance("ghr-1", "TERMINATED"), "ghr-2": instance("ghr-2", "RUNNING")}
    summary = controller(github, compute).reconcile()
    assert summary["finished"] == 1 and compute.deleted == ["ghr-1"]


def test_reconcile_keeps_busy_and_young_vms(github: FakeGitHub, compute: FakeCompute) -> None:
    compute.instances = {
        "ghr-busy": instance("ghr-busy", age_seconds=3600),
        "ghr-young": instance("ghr-young", age_seconds=60),
    }
    github.runners = {
        "ghr-busy": {"id": 1, "name": "ghr-busy", "busy": True, "status": "online"},
        "ghr-young": {"id": 2, "name": "ghr-young", "busy": False, "status": "offline"},
    }
    summary = controller(github, compute).reconcile()
    assert compute.deleted == [] and github.deleted == [] and summary["errors"] == 0


def test_reconcile_retires_idle_vms(github: FakeGitHub, compute: FakeCompute) -> None:
    compute.instances = {"ghr-idle": instance("ghr-idle", age_seconds=1000), "ghr-gone": instance("ghr-gone", age_seconds=1000)}
    github.runners = {"ghr-idle": {"id": 1, "name": "ghr-idle", "busy": False, "status": "online"}}
    summary = controller(github, compute).reconcile()
    assert summary["idle"] == 2
    assert sorted(compute.deleted) == ["ghr-gone", "ghr-idle"] and github.deleted == [1]


def test_reconcile_deletes_orphan_runner_registrations(github: FakeGitHub, compute: FakeCompute) -> None:
    github.runners = {
        "ghr-orphan": {"id": 1, "name": "ghr-orphan", "busy": False, "status": "offline"},
        "ghr-online": {"id": 2, "name": "ghr-online", "busy": False, "status": "online"},
    }
    summary = controller(github, compute).reconcile()
    assert summary["orphan_runners"] == 1 and github.deleted == [1]


def test_reconcile_starts_vms_for_jobs_whose_webhook_was_lost(github: FakeGitHub, compute: FakeCompute) -> None:
    old = "2027-01-15T07:55:00Z"  # NOW is 2027-01-15T08:00:00Z
    github.jobs = {
        "app": [
            {"id": 11, "labels": ["self-hosted", "gcp-x64"], "created_at": old},
            {"id": 12, "labels": ["ubuntu-latest"], "created_at": old},
            {"id": 13, "labels": ["gcp-x64"], "created_at": "2027-01-15T07:59:30Z"},
        ]
    }
    compute.instances = {"ghr-14": instance("ghr-14")}
    github.jobs["app"].append({"id": 14, "labels": ["gcp-x64"], "created_at": old})

    summary = controller(github, compute, repositories=("app",)).reconcile()

    assert summary["started"] == 1
    assert [name for _, name, _ in compute.inserts] == ["ghr-11"]


def test_reconcile_continues_after_a_failure(github: FakeGitHub, compute: FakeCompute) -> None:
    compute.instances = {"ghr-1": instance("ghr-1", "TERMINATED"), "ghr-2": instance("ghr-2", "TERMINATED")}

    def flaky_delete(inst: dict[str, object]) -> None:
        if inst["name"] == "ghr-1":
            raise ComputeError("boom")
        compute.deleted.append(str(inst["name"]))

    compute.delete = flaky_delete  # type: ignore[method-assign]
    summary = controller(github, compute).reconcile()
    assert summary["errors"] == 1 and compute.deleted == ["ghr-2"]


def test_webhook_response_is_json_serializable(github: FakeGitHub, compute: FakeCompute) -> None:
    _, response = controller(github, compute).handle_webhook(*webhook_request("queued", job(1001)), SECRET)
    json.dumps(response)
