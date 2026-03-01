import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

from fastapi import HTTPException
from fastapi.testclient import TestClient


SERVER_APP_ROOT = Path(__file__).resolve().parents[1]
if str(SERVER_APP_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVER_APP_ROOT))

from main import app, get_postgres_dsn, is_placeholder_value, normalize_postgres_dsn  # noqa: E402


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
            "game_id": game_id,
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
                "game_id": game_id,
                "ply": 1,
                "move_uci": "e2e4",
                "created_at": created_at,
            },
            {
                "game_id": game_id,
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


def test_enqueue_matchmaking_returns_ticket(monkeypatch) -> None:
    player_id = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    ticket_id = uuid.UUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
    expires_at = datetime(2026, 3, 1, 12, 0, tzinfo=timezone.utc)
    heartbeat_at = datetime(2026, 3, 1, 11, 59, tzinfo=timezone.utc)
    monkeypatch.setattr(
        "main.enqueue_player_for_matchmaking",
        lambda player_id: {
            "ticket_id": ticket_id,
            "player_id": player_id,
            "status": "queued",
            "match_id": None,
            "assigned_color": None,
            "heartbeat_at": heartbeat_at,
            "expires_at": expires_at,
            "poll_after_ms": 1000,
        },
    )

    client = TestClient(app)
    response = client.post("/v1/matchmaking/enqueue", json={"player_id": str(player_id)})

    assert response.status_code == 200
    assert response.json()["ticket_id"] == str(ticket_id)
    assert response.json()["status"] == "queued"


def test_heartbeat_matchmaking_refreshes_ticket(monkeypatch) -> None:
    player_id = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    ticket_id = uuid.UUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
    match_id = uuid.UUID("cccccccc-cccc-cccc-cccc-cccccccccccc")
    expires_at = datetime(2026, 3, 1, 12, 0, tzinfo=timezone.utc)
    heartbeat_at = datetime(2026, 3, 1, 11, 59, tzinfo=timezone.utc)
    monkeypatch.setattr(
        "main.heartbeat_matchmaking_ticket",
        lambda ticket_id, player_id: {
            "ticket_id": ticket_id,
            "player_id": player_id,
            "status": "matched",
            "match_id": match_id,
            "assigned_color": "white",
            "heartbeat_at": heartbeat_at,
            "expires_at": expires_at,
            "poll_after_ms": 1000,
        },
    )

    client = TestClient(app)
    response = client.post(
        f"/v1/matchmaking/{ticket_id}/heartbeat",
        json={"player_id": str(player_id)},
    )

    assert response.status_code == 200
    assert response.json()["status"] == "matched"
    assert response.json()["assigned_color"] == "white"


def test_get_matchmaking_ticket_returns_status(monkeypatch) -> None:
    player_id = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    ticket_id = uuid.UUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
    expires_at = datetime(2026, 3, 1, 12, 0, tzinfo=timezone.utc)
    heartbeat_at = datetime(2026, 3, 1, 11, 59, tzinfo=timezone.utc)
    monkeypatch.setattr(
        "main.get_matchmaking_ticket",
        lambda ticket_id, player_id=None: {
            "ticket_id": ticket_id,
            "player_id": player_id,
            "status": "queued",
            "match_id": None,
            "assigned_color": None,
            "heartbeat_at": heartbeat_at,
            "expires_at": expires_at,
            "poll_after_ms": 1000,
        },
    )

    client = TestClient(app)
    response = client.get(f"/v1/matchmaking/{ticket_id}", params={"player_id": str(player_id)})

    assert response.status_code == 200
    assert response.json()["player_id"] == str(player_id)


def test_cancel_matchmaking_ticket_returns_cancelled(monkeypatch) -> None:
    player_id = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    ticket_id = uuid.UUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
    expires_at = datetime(2026, 3, 1, 12, 0, tzinfo=timezone.utc)
    heartbeat_at = datetime(2026, 3, 1, 11, 59, tzinfo=timezone.utc)
    monkeypatch.setattr(
        "main.cancel_matchmaking_ticket",
        lambda ticket_id, player_id: {
            "ticket_id": ticket_id,
            "player_id": player_id,
            "status": "cancelled",
            "match_id": None,
            "assigned_color": None,
            "heartbeat_at": heartbeat_at,
            "expires_at": expires_at,
            "poll_after_ms": 1000,
        },
    )

    client = TestClient(app)
    response = client.delete(f"/v1/matchmaking/{ticket_id}", params={"player_id": str(player_id)})

    assert response.status_code == 200
    assert response.json()["status"] == "cancelled"


def test_get_match_state_returns_current_server_state(monkeypatch) -> None:
    player_id = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    match_id = uuid.UUID("dddddddd-dddd-dddd-dddd-dddddddddddd")
    game_id = uuid.UUID("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")
    created_at = datetime(2026, 3, 1, 12, 0, tzinfo=timezone.utc)
    monkeypatch.setattr(
        "main.get_match_state_record",
        lambda match_id, player_id=None: {
            "match_id": match_id,
            "game_id": game_id,
            "status": "active",
            "white_player_id": player_id,
            "black_player_id": uuid.UUID("ffffffff-ffff-ffff-ffff-ffffffffffff"),
            "your_color": "white",
            "latest_ply": 2,
            "next_turn": "white",
            "moves": [
                {
                    "match_id": match_id,
                    "game_id": game_id,
                    "ply": 1,
                    "move_uci": "e2e4",
                    "player_id": player_id,
                    "created_at": created_at,
                }
            ],
        },
    )

    client = TestClient(app)
    response = client.get(f"/v1/matches/{match_id}/state", params={"player_id": str(player_id)})

    assert response.status_code == 200
    assert response.json()["your_color"] == "white"
    assert response.json()["next_turn"] == "white"


def test_post_match_move_returns_conflict_with_current_state(monkeypatch) -> None:
    player_id = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    match_id = uuid.UUID("dddddddd-dddd-dddd-dddd-dddddddddddd")
    current_state = {
        "match_id": str(match_id),
        "game_id": "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
        "status": "active",
        "your_color": "white",
        "latest_ply": 2,
        "next_turn": "white",
        "moves": [],
    }

    def fake_record_queue_match_move(
        match_id: uuid.UUID,
        player_id: uuid.UUID,
        ply: int,
        move_uci: str,
    ) -> dict[str, object]:
        raise HTTPException(
            status_code=409,
            detail={
                "message": "Expected ply 3, received 2.",
                "current_state": current_state,
            },
        )

    monkeypatch.setattr("main.record_queue_match_move", fake_record_queue_match_move)

    client = TestClient(app)
    response = client.post(
        f"/v1/matches/{match_id}/moves",
        json={"player_id": str(player_id), "ply": 2, "move_uci": "d2d4"},
    )

    assert response.status_code == 409
    assert response.json()["detail"]["current_state"]["latest_ply"] == 2


def test_get_match_moves_supports_after_ply(monkeypatch) -> None:
    match_id = uuid.UUID("dddddddd-dddd-dddd-dddd-dddddddddddd")
    game_id = uuid.UUID("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")
    player_id = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    created_at = datetime(2026, 3, 1, 12, 0, tzinfo=timezone.utc)
    monkeypatch.setattr(
        "main.get_queue_match_moves",
        lambda match_id, after_ply, player_id=None: {
            "match_id": match_id,
            "game_id": game_id,
            "latest_ply": 4,
            "next_turn": "white",
            "moves": [
                {
                    "match_id": match_id,
                    "game_id": game_id,
                    "ply": 3,
                    "move_uci": "g1f3",
                    "player_id": player_id,
                    "created_at": created_at,
                },
                {
                    "match_id": match_id,
                    "game_id": game_id,
                    "ply": 4,
                    "move_uci": "b8c6",
                    "player_id": uuid.UUID("ffffffff-ffff-ffff-ffff-ffffffffffff"),
                    "created_at": created_at,
                },
            ],
        },
    )

    client = TestClient(app)
    response = client.get(
        f"/v1/matches/{match_id}/moves",
        params={"after_ply": 2, "player_id": str(player_id)},
    )

    assert response.status_code == 200
    assert [item["ply"] for item in response.json()["moves"]] == [3, 4]


def test_get_postgres_dsn_prefers_railway_private_url(monkeypatch) -> None:
    monkeypatch.setenv("DATABASE_PRIVATE_URL", "postgres://user:pass@private-host:5432/railway")
    monkeypatch.setenv("DATABASE_URL", "postgresql://user:pass@public-host:5432/railway")

    assert get_postgres_dsn() == "postgresql://user:pass@private-host:5432/railway"


def test_get_postgres_dsn_supports_pg_fallback_vars(monkeypatch) -> None:
    monkeypatch.delenv("DATABASE_PRIVATE_URL", raising=False)
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.delenv("DATABASE_PUBLIC_URL", raising=False)
    monkeypatch.setenv("PGHOST", "railway.internal")
    monkeypatch.setenv("PGPORT", "5432")
    monkeypatch.setenv("PGDATABASE", "railway")
    monkeypatch.setenv("PGUSER", "postgres")
    monkeypatch.setenv("PGPASSWORD", "secret")

    assert get_postgres_dsn() == "postgresql://postgres:secret@railway.internal:5432/railway"


def test_normalize_postgres_dsn_rewrites_postgres_scheme() -> None:
    assert normalize_postgres_dsn("postgres://user:pass@host:5432/db") == (
        "postgresql://user:pass@host:5432/db"
    )


def test_get_postgres_dsn_skips_placeholder_database_url(monkeypatch) -> None:
    monkeypatch.delenv("DATABASE_PRIVATE_URL", raising=False)
    monkeypatch.delenv("DATABASE_PUBLIC_URL", raising=False)
    monkeypatch.setenv(
        "DATABASE_URL",
        "postgresql://postgres:password@your-railway-postgres-host:5432/railway",
    )
    monkeypatch.setenv("PGHOST", "railway.internal")
    monkeypatch.setenv("PGPORT", "5432")
    monkeypatch.setenv("PGDATABASE", "railway")
    monkeypatch.setenv("PGUSER", "postgres")
    monkeypatch.setenv("PGPASSWORD", "secret")

    assert get_postgres_dsn() == "postgresql://postgres:secret@railway.internal:5432/railway"


def test_is_placeholder_value_detects_template_markers() -> None:
    assert is_placeholder_value("postgresql://x:y@your-railway-postgres-host:5432/railway")
    assert is_placeholder_value("https://your-railway-service.up.railway.app")
