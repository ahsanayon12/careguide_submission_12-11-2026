import json
import logging

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.logging_config import JsonFormatter
from app.main import app


@pytest.fixture()
def client() -> TestClient:
    with TestClient(app) as c:
        yield c


def test_root_returns_expected_payload(client: TestClient) -> None:
    resp = client.get("/")
    assert resp.status_code == 200
    body = resp.json()
    assert body["message"] == "Hello from DevOps Task!"
    assert body["status"] == "running"
    assert "version" in body and body["version"]


def test_health_ok(client: TestClient) -> None:
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_metrics_exposes_prometheus_format(client: TestClient) -> None:
    client.get("/")
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("text/plain")
    text = resp.text
    assert "http_requests_total" in text
    assert "http_request_errors_total" in text
    assert "http_request_duration_seconds_bucket" in text
    assert 'path="/"' in text


def test_unknown_path_uses_bounded_label(client: TestClient) -> None:
    resp = client.get("/does-not-exist/12345")
    assert resp.status_code == 404
    metrics = client.get("/metrics").text
    assert 'path="unmatched"' in metrics
    assert "/does-not-exist/12345" not in metrics


def test_settings_read_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("PORT", "9090")
    monkeypatch.setenv("LOG_LEVEL", "debug")
    monkeypatch.setenv("ENVIRONMENT", "staging")
    monkeypatch.setenv("APP_VERSION", "1.2.3")
    s = Settings.from_env()
    assert s.port == 9090
    assert s.log_level == "DEBUG"
    assert s.environment == "staging"
    assert s.app_version == "1.2.3"


def test_settings_fall_back_on_invalid_values(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("PORT", "not-a-number")
    monkeypatch.setenv("LOG_LEVEL", "verbose")
    s = Settings.from_env()
    assert s.port == 8080
    assert s.log_level == "INFO"


def test_json_formatter_emits_structured_log() -> None:
    formatter = JsonFormatter(service="svc", environment="test", version="1.0.0")
    record = logging.makeLogRecord(
        {"name": "t", "levelname": "INFO", "levelno": 20, "msg": "hello", "path": "/x"}
    )
    out = json.loads(formatter.format(record))
    assert out["msg"] == "hello"
    assert out["level"] == "info"
    assert out["path"] == "/x"
    assert out["service"] == "svc"
    assert out["env"] == "test"
