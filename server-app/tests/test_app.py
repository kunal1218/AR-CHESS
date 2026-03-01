import uuid
from datetime import datetime, timezone

from fastapi.testclient import TestClient

from main import app, get_postgres_dsn, is_placeholder_value, normalize_postgres_dsn


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


def test_get_postgres_dsn_prefers_railway_private_url(monkeypatch) -> None:
    monkeypatch.setenv("DATABASE_PRIVATE_URL", "postgres://user:pass@private-host:5432/railway")
    monkeypatch.setenv("DATABASE_URL", "postgresql://user:pass@public-host:5432/railway")

    assert get_postgres_dsn() == "postgresql://user:pass@private-host:5432/railway"


def test_get_postgres_dsn_supports_pg_fallback_vars(monkeypatch) -> None:
    monkeypatch.delenv("DATABASE_PRIVATE_URL", raising=False)
    monkeypatch.delenv("DATABASE_URL", raising=False)
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
