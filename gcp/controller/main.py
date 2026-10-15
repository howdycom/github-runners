"""Cloud Run function entry points: `webhook` (GitHub) and `reconcile` (Cloud Scheduler)."""

from __future__ import annotations

import functools
import json
import os
import traceback

import functions_framework
from flask import Request

from ghr import log
from ghr.compute import Compute
from ghr.config import Config
from ghr.controller import Controller
from ghr.github import GitHubApp, GitHubClient

JSON_HEADERS = {"Content-Type": "application/json"}


@functools.cache
def _controller() -> Controller:
    config = Config.from_env()
    app = GitHubApp(config.app_id, config.installation_id, os.environ["GITHUB_APP_PRIVATE_KEY"])
    return Controller(config, GitHubClient(app, config.github_org), Compute(config.project, config.name_prefix))


def _webhook_secret() -> bytes:
    return os.environ["GITHUB_WEBHOOK_SECRET"].encode()


@functions_framework.http
def webhook(request: Request) -> tuple[str, int, dict[str, str]]:
    try:
        status, body = _controller().handle_webhook(request.headers, request.get_data(), _webhook_secret())
    except Exception as exc:
        log.error("webhook failed", detail=str(exc), traceback=traceback.format_exc())
        status, body = 500, {"error": "internal error"}
    return json.dumps(body), status, JSON_HEADERS


@functions_framework.http
def reconcile(request: Request) -> tuple[str, int, dict[str, str]]:
    try:
        summary = _controller().reconcile()
    except Exception as exc:
        log.error("reconcile failed", detail=str(exc), traceback=traceback.format_exc())
        return json.dumps({"error": "internal error"}), 500, JSON_HEADERS
    return json.dumps(summary), 200, JSON_HEADERS
