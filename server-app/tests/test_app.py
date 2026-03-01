import uuid
from datetime import datetime, timezone

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


def test_create_game_returns_generated_game_id(monkeypatch) -> None:
    game_id = uuid.UUID("11111111-1111-1111-1111-111111111111")
    monkeypatch.setattr("main.create_game_record", lambda: game_id)

    client = TestClient(app)
    response = client.post("/v1/games")

    assert response.status_code == 200
    assert response.json() == {"game_id": str(game_id)}


def test_record_game_move_persists_uci_move(monkeypatch) -> None:
    game_id = uuid.UUID("22222222-2222-2222-2222-222222222222")
    created_at = datetime(2026, 2, 28, 12, 0, tzinfo=timezone.utc)

    def fake_save_game_move(game_id: uuid.UUID, ply: int, move_uci: str) -> dict[str, object]:
        return {
            "game_id": str(game_id),
            "ply": ply,
            "move_uci": move_uci,
            "created_at": created_at,
        }

    monkeypatch.setattr("main.save_game_move", fake_save_game_move)

    client = TestClient(app)
    response = client.post(
        f"/v1/games/{game_id}/moves",
        json={"ply": 1, "move_uci": "E2E4"},
    )

    assert response.status_code == 200
    assert response.json()["game_id"] == str(game_id)
    assert response.json()["ply"] == 1
    assert response.json()["move_uci"] == "e2e4"


def test_record_game_move_rejects_non_uci_notation() -> None:
    game_id = uuid.UUID("33333333-3333-3333-3333-333333333333")
    client = TestClient(app)
    response = client.post(
        f"/v1/games/{game_id}/moves",
        json={"ply": 1, "move_uci": "Nf3+"},
    )

    assert response.status_code == 422
    assert "UCI notation" in response.text


def test_get_game_moves_returns_ordered_log(monkeypatch) -> None:
    game_id = uuid.UUID("44444444-4444-4444-4444-444444444444")
    created_at = datetime(2026, 2, 28, 12, 0, tzinfo=timezone.utc)
    monkeypatch.setattr(
        "main.fetch_game_moves",
        lambda game_id: [
            {
                "game_id": str(game_id),
                "ply": 1,
                "move_uci": "e2e4",
                "created_at": created_at,
            },
            {
                "game_id": str(game_id),
                "ply": 2,
                "move_uci": "e7e5",
                "created_at": created_at,
            },
        ],
    )

    client = TestClient(app)
    response = client.get(f"/v1/games/{game_id}/moves")

    assert response.status_code == 200
    assert response.json()["game_id"] == str(game_id)
    assert [item["move_uci"] for item in response.json()["moves"]] == ["e2e4", "e7e5"]
