from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import jwt
import pytest
from conftest import SECRET, sign
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from ghr.github import GitHubApp, GitHubClient, GitHubError, RunnerNameTaken, verify_signature

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
    responses: dict[tuple[str, str], list[FakeResponse]]
    calls: list[tuple[str, str, dict[str, Any]]] = field(default_factory=list)

    def _respond(self, method: str, url: str, **kwargs: Any) -> FakeResponse:
        self.calls.append((method, url, kwargs))
        path = url.removeprefix("https://api.github.com")
        queue = self.responses[(method, path)]
        return queue.pop(0) if len(queue) > 1 else queue[0]

    def post(self, url: str, **kwargs: Any) -> FakeResponse:
        return self._respond("POST", url, **kwargs)

    def request(self, method: str, url: str, **kwargs: Any) -> FakeResponse:
        return self._respond(method, url, **kwargs)


@pytest.fixture(scope="module")
def private_key() -> rsa.RSAPrivateKey:
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def pem(key: rsa.RSAPrivateKey) -> str:
    return key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode()


def token_response(expires_at: str = "2027-01-15T09:00:00Z") -> FakeResponse:
    return FakeResponse(201, {"token": "installation-token", "expires_at": expires_at})


def make_client(private_key: rsa.RSAPrivateKey, responses: dict[tuple[str, str], list[FakeResponse]], clock: list[float] | None = None) -> tuple[GitHubClient, FakeSession]:
    responses.setdefault(("POST", "/app/installations/42/access_tokens"), [token_response()])
    session = FakeSession(responses)
    now = clock or [NOW]
    app = GitHubApp("123", 42, pem(private_key), session=session, clock=lambda: now[0])  # type: ignore[arg-type]
    return GitHubClient(app, "example-org"), session


def test_verify_signature() -> None:
    body = b'{"a": 1}'
    assert verify_signature(SECRET, body, sign(body))
    assert not verify_signature(SECRET, body, sign(body, b"other"))
    assert not verify_signature(SECRET, body + b" ", sign(body))
    assert not verify_signature(SECRET, body, None)
    assert not verify_signature(SECRET, body, "sha1=abc")
    assert not verify_signature(b"", body, sign(body, b""))


def test_app_jwt_is_signed_and_short_lived(private_key: rsa.RSAPrivateKey) -> None:
    client, session = make_client(private_key, {("GET", "/orgs/example-org/actions/runners"): [FakeResponse(200, {"runners": []})]})
    client.list_runners("ghr-")

    method, url, kwargs = session.calls[0]
    assert (method, url) == ("POST", "https://api.github.com/app/installations/42/access_tokens")
    token = kwargs["headers"]["Authorization"].removeprefix("Bearer ")
    claims = jwt.decode(token, private_key.public_key(), algorithms=["RS256"], options={"verify_exp": False, "verify_iat": False})
    assert claims["iss"] == "123"
    assert claims["exp"] - claims["iat"] <= 600
    assert session.calls[1][2]["headers"]["Authorization"] == "Bearer installation-token"


def test_installation_token_is_cached_until_close_to_expiry(private_key: rsa.RSAPrivateKey) -> None:
    clock = [NOW]
    client, session = make_client(
        private_key, {("GET", "/orgs/example-org/actions/runners"): [FakeResponse(200, {"runners": []})]}, clock
    )
    client.list_runners("ghr-")
    client.list_runners("ghr-")
    assert sum(1 for m, u, _ in session.calls if u.endswith("/access_tokens")) == 1

    clock[0] = NOW + 3600 - 200  # inside the refresh margin
    client.list_runners("ghr-")
    assert sum(1 for m, u, _ in session.calls if u.endswith("/access_tokens")) == 2


def test_generate_jit_config(private_key: rsa.RSAPrivateKey) -> None:
    client, session = make_client(
        private_key,
        {("POST", "/orgs/example-org/actions/runners/generate-jitconfig"): [FakeResponse(201, {"runner": {"id": 77}, "encoded_jit_config": "abc"})]},
    )
    assert client.generate_jit_config("ghr-1", 7, ("self-hosted", "gcp-x64")) == (77, "abc")
    assert session.calls[-1][2]["json"] == {"name": "ghr-1", "runner_group_id": 7, "labels": ["self-hosted", "gcp-x64"]}


def test_generate_jit_config_name_taken(private_key: rsa.RSAPrivateKey) -> None:
    client, _ = make_client(private_key, {("POST", "/orgs/example-org/actions/runners/generate-jitconfig"): [FakeResponse(409)]})
    with pytest.raises(RunnerNameTaken):
        client.generate_jit_config("ghr-1", 7, ("gcp-x64",))


@pytest.mark.parametrize(("status", "expected"), [(200, True), (204, True), (404, True), (422, False)])
def test_delete_runner(private_key: rsa.RSAPrivateKey, status: int, expected: bool) -> None:
    client, _ = make_client(private_key, {("DELETE", "/orgs/example-org/actions/runners/5"): [FakeResponse(status)]})
    assert client.delete_runner(5) is expected


def test_delete_runner_raises_on_server_error(private_key: rsa.RSAPrivateKey) -> None:
    client, _ = make_client(private_key, {("DELETE", "/orgs/example-org/actions/runners/5"): [FakeResponse(500, text="oops")]})
    with pytest.raises(GitHubError):
        client.delete_runner(5)


def test_list_runners_paginates_and_filters_by_prefix(private_key: rsa.RSAPrivateKey) -> None:
    page1 = [{"name": f"ghr-{i}"} for i in range(99)] + [{"name": "other"}]
    client, _ = make_client(
        private_key,
        {("GET", "/orgs/example-org/actions/runners"): [FakeResponse(200, {"runners": page1}), FakeResponse(200, {"runners": [{"name": "ghr-x"}]})]},
    )
    names = [r["name"] for r in client.list_runners("ghr-")]
    assert len(names) == 100 and "other" not in names and names[-1] == "ghr-x"


def test_runner_group_lookup(private_key: rsa.RSAPrivateKey) -> None:
    groups = [{"id": 1, "name": "Default"}, {"id": 7, "name": "GCP-Runners"}]
    client, _ = make_client(private_key, {("GET", "/orgs/example-org/actions/runner-groups"): [FakeResponse(200, {"runner_groups": groups})]})
    assert client.runner_group("gcp-runners")["id"] == 7
    with pytest.raises(GitHubError):
        client.runner_group("missing")


def test_queued_jobs_include_jobs_in_running_workflows(private_key: rsa.RSAPrivateKey) -> None:
    client, _ = make_client(
        private_key,
        {
            ("GET", "/repos/example-org/app/actions/runs"): [
                FakeResponse(200, {"workflow_runs": [{"id": 1}]}),
                FakeResponse(200, {"workflow_runs": [{"id": 2}]}),
            ],
            ("GET", "/repos/example-org/app/actions/runs/1/jobs"): [FakeResponse(200, {"jobs": [{"id": 10, "status": "queued"}]})],
            ("GET", "/repos/example-org/app/actions/runs/2/jobs"): [
                FakeResponse(200, {"jobs": [{"id": 20, "status": "in_progress"}, {"id": 21, "status": "queued"}]})
            ],
        },
    )
    assert [j["id"] for j in client.queued_jobs("app")] == [10, 21]


def test_repository(private_key: rsa.RSAPrivateKey) -> None:
    client, _ = make_client(private_key, {("GET", "/repos/example-org/app"): [FakeResponse(200, {"name": "app", "private": True})]})
    assert client.repository("app")["private"] is True
