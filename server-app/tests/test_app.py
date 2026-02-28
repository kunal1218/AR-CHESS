from fastapi.testclient import TestClient

from main import app


def test_fastapi_app_bootstraps() -> None:
    assert app.title == "AR Chess Server"


def test_health_ping_reports_server_and_postgres(monkeypatch) -> None:
    monkeypatch.setattr("main.ping_postgres", lambda: (True, "Postgres ping successful"))

    client = TestClient(app)
    response = client.get("/health/ping")

    assert response.status_code == 200
    assert response.json()["messages"] == [
        "Server ping successful",
        "Postgres ping successful",
    ]
