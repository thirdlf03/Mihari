"""トークン認証。"""

from __future__ import annotations

from fastapi.testclient import TestClient


def test_health_requires_token(client: TestClient, auth: dict[str, str]) -> None:
    # /health は safety の中身や pid を含むため、無認証には出さない。
    # アプリは起動直後からトークンを持っているので、認証を付けても叩ける。
    assert client.get("/health").status_code == 401

    response = client.get("/health", headers=auth)
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_devices_without_token_is_rejected(client: TestClient) -> None:
    assert client.get("/devices").status_code == 401


def test_devices_with_wrong_token_is_rejected(client: TestClient) -> None:
    response = client.get("/devices", headers={"X-Mihari-Token": "wrong"})
    assert response.status_code == 401


def test_events_without_token_is_rejected(client: TestClient) -> None:
    assert client.get("/events").status_code == 401
    assert client.post("/events/publish", json={"name": "x"}).status_code == 401
