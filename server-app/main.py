import logging
import os
import re
import uuid
from contextlib import suppress
from datetime import datetime, timedelta, timezone
from typing import Any
from urllib.parse import urlparse

import psycopg
from fastapi import FastAPI, HTTPException, Query, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, field_validator


logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("archess.server")

DEFAULT_POSTGRES_PORT = 5432
TICKET_TTL_SECONDS = int(os.getenv("MATCH_TICKET_TTL_SECONDS", "30"))
UCI_MOVE_PATTERN = re.compile(r"^[a-h][1-8][a-h][1-8][qrbn]?$", re.IGNORECASE)
ACTIVE_TICKET_STATUSES = ("queued", "matched")

app = FastAPI(title="AR Chess Server", version="0.3.0")


class EnqueueMatchmakingRequest(BaseModel):
    player_id: uuid.UUID


class MatchmakingTicketActionRequest(BaseModel):
    player_id: uuid.UUID


class GameMoveRequest(BaseModel):
    ply: int = Field(..., ge=1)
    move_uci: str

    @field_validator("move_uci")
    @classmethod
    def validate_uci_move(cls, value: str) -> str:
        move = value.strip().lower()
        if not UCI_MOVE_PATTERN.match(move):
            raise ValueError("Move must be valid UCI notation such as e2e4, e1g1, or e7e8q.")
        return move


class QueueMatchMoveRequest(GameMoveRequest):
    player_id: uuid.UUID


class TicketResponse(BaseModel):
    ticket_id: uuid.UUID
    player_id: uuid.UUID
    status: str
    match_id: uuid.UUID | None = None
    assigned_color: str | None = None
    heartbeat_at: datetime
    expires_at: datetime
    poll_after_ms: int = 1000


class GameMoveRecord(BaseModel):
    game_id: uuid.UUID
    ply: int
    move_uci: str
    created_at: datetime


class MatchMoveRecord(BaseModel):
    match_id: uuid.UUID
    game_id: uuid.UUID
    ply: int
    move_uci: str
    player_id: uuid.UUID
    created_at: datetime


class MatchStateResponse(BaseModel):
    match_id: uuid.UUID
    game_id: uuid.UUID
    status: str
    white_player_id: uuid.UUID
    black_player_id: uuid.UUID
    your_color: str | None
    latest_ply: int
    next_turn: str
    moves: list[MatchMoveRecord]


class MatchMovesResponse(BaseModel):
    match_id: uuid.UUID
    game_id: uuid.UUID
    latest_ply: int
    next_turn: str
    moves: list[MatchMoveRecord]


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def is_placeholder_value(value: str | None) -> bool:
    if not value:
        return False
    return "your-railway" in value or "example" in value


def normalize_postgres_dsn(value: str) -> str:
    if value.startswith("postgres://"):
        return "postgresql://" + value[len("postgres://") :]
    return value


def get_postgres_dsn() -> str:
    direct_candidates = (
        os.getenv("DATABASE_PRIVATE_URL"),
        os.getenv("DATABASE_URL"),
        os.getenv("DATABASE_PUBLIC_URL"),
    )
    for candidate in direct_candidates:
        if candidate and not is_placeholder_value(candidate):
            return normalize_postgres_dsn(candidate)

    pg_host = os.getenv("PGHOST")
    pg_port = os.getenv("PGPORT", str(DEFAULT_POSTGRES_PORT))
    pg_database = os.getenv("PGDATABASE")
    pg_user = os.getenv("PGUSER")
    pg_password = os.getenv("PGPASSWORD")

    if all((pg_host, pg_database, pg_user, pg_password)) and not is_placeholder_value(pg_host):
        return normalize_postgres_dsn(
            f"postgresql://{pg_user}:{pg_password}@{pg_host}:{pg_port}/{pg_database}"
        )

    legacy_host = os.getenv("POSTGRES_HOST", "127.0.0.1")
    legacy_port = os.getenv("POSTGRES_PORT", str(DEFAULT_POSTGRES_PORT))
    legacy_database = os.getenv("POSTGRES_DB", "postgres")
    legacy_user = os.getenv("POSTGRES_USER", "postgres")
    legacy_password = os.getenv("POSTGRES_PASSWORD", "postgres")
    return normalize_postgres_dsn(
        f"postgresql://{legacy_user}:{legacy_password}@{legacy_host}:{legacy_port}/{legacy_database}"
    )


def redact_postgres_host(dsn: str) -> str:
    with suppress(Exception):
        parsed = urlparse(dsn)
        if parsed.hostname:
            return parsed.hostname
    return "unparsed-host"


def connect_postgres() -> psycopg.Connection:
    dsn = get_postgres_dsn()
    logger.info("Connecting to Postgres using DSN source host=%s", redact_postgres_host(dsn))
    return psycopg.connect(dsn, connect_timeout=5)


def ping_postgres() -> tuple[bool, str]:
    try:
        with connect_postgres() as connection:
            with connection.cursor() as cursor:
                cursor.execute("SELECT 1")
                cursor.fetchone()
        return True, "Postgres ping successful"
    except Exception as exc:  # pragma: no cover - covered indirectly via routes
        logger.exception("Postgres ping failed")
        return False, f"Postgres ping failed: {exc}"


def ensure_schema_ready(connection: psycopg.Connection | None = None) -> None:
    if connection is None:
        with connect_postgres() as owned_connection:
            ensure_schema_ready(owned_connection)
        return

    with connection.cursor() as cursor:
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS games (
                id UUID PRIMARY KEY,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """
        )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS game_moves (
                id BIGSERIAL PRIMARY KEY,
                game_id UUID NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                ply BIGINT NOT NULL,
                move_uci TEXT NOT NULL,
                player_id UUID NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                UNIQUE (game_id, ply)
            )
            """
        )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS matches (
                id UUID PRIMARY KEY,
                game_id UUID NOT NULL UNIQUE REFERENCES games(id) ON DELETE CASCADE,
                white_player_id UUID NOT NULL,
                black_player_id UUID NOT NULL,
                status TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                CHECK (white_player_id <> black_player_id)
            )
            """
        )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS tickets (
                id UUID PRIMARY KEY,
                player_id UUID NOT NULL,
                status TEXT NOT NULL,
                heartbeat_at TIMESTAMPTZ NOT NULL,
                expires_at TIMESTAMPTZ NOT NULL,
                match_id UUID NULL REFERENCES matches(id) ON DELETE SET NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """
        )
        cursor.execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS tickets_one_active_per_player_idx
            ON tickets (player_id)
            WHERE status IN ('queued', 'matched')
            """
        )
        cursor.execute(
            """
            CREATE INDEX IF NOT EXISTS tickets_status_expires_idx
            ON tickets (status, expires_at, created_at)
            """
        )
        cursor.execute(
            """
            CREATE INDEX IF NOT EXISTS game_moves_game_ply_idx
            ON game_moves (game_id, ply)
            """
        )


def create_game_record(connection: psycopg.Connection | None = None) -> uuid.UUID:
    game_id = uuid.uuid4()
    if connection is None:
        with connect_postgres() as owned_connection, owned_connection.transaction():
            ensure_schema_ready(owned_connection)
            with owned_connection.cursor() as cursor:
                cursor.execute("INSERT INTO games (id) VALUES (%s)", (game_id,))
        return game_id

    with connection.cursor() as cursor:
        cursor.execute("INSERT INTO games (id) VALUES (%s)", (game_id,))
    return game_id


def save_game_move(game_id: uuid.UUID, ply: int, move_uci: str) -> dict[str, Any]:
    with connect_postgres() as connection, connection.transaction():
        ensure_schema_ready(connection)
        with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
            cursor.execute(
                """
                INSERT INTO game_moves (game_id, ply, move_uci)
                VALUES (%s, %s, %s)
                ON CONFLICT (game_id, ply)
                DO UPDATE SET move_uci = EXCLUDED.move_uci
                RETURNING game_id, ply, move_uci, created_at
                """,
                (game_id, ply, move_uci),
            )
            record = cursor.fetchone()
            if record is None:
                raise HTTPException(status_code=500, detail="Could not store game move.")
    return record


def fetch_game_moves(game_id: uuid.UUID) -> list[dict[str, Any]]:
    with connect_postgres() as connection, connection.transaction():
        ensure_schema_ready(connection)
        with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
            cursor.execute(
                """
                SELECT game_id, ply, move_uci, created_at
                FROM game_moves
                WHERE game_id = %s
                ORDER BY ply ASC
                """,
                (game_id,),
            )
            return list(cursor.fetchall())


def expire_stale_tickets(connection: psycopg.Connection) -> None:
    with connection.cursor() as cursor:
        cursor.execute(
            """
            UPDATE tickets
            SET status = 'expired', updated_at = NOW()
            WHERE status = 'queued' AND expires_at < NOW()
            """
        )


def ticket_expiry_from_now() -> datetime:
    return utcnow() + timedelta(seconds=TICKET_TTL_SECONDS)


def next_turn_for_ply(latest_ply: int) -> str:
    return "white" if latest_ply % 2 == 0 else "black"


def color_for_player(match_row: dict[str, Any], player_id: uuid.UUID) -> str | None:
    if player_id == match_row["white_player_id"]:
        return "white"
    if player_id == match_row["black_player_id"]:
        return "black"
    return None


def fetch_ticket_row(
    connection: psycopg.Connection,
    ticket_id: uuid.UUID,
    player_id: uuid.UUID | None = None,
    for_update: bool = False,
) -> dict[str, Any] | None:
    query = """
        SELECT id, player_id, status, heartbeat_at, expires_at, match_id, created_at, updated_at
        FROM tickets
        WHERE id = %s
    """
    params: list[Any] = [ticket_id]
    if player_id is not None:
        query += " AND player_id = %s"
        params.append(player_id)
    if for_update:
        query += " FOR UPDATE"

    with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
        cursor.execute(query, params)
        return cursor.fetchone()


def fetch_match_row(
    connection: psycopg.Connection,
    match_id: uuid.UUID,
    for_update: bool = False,
) -> dict[str, Any] | None:
    query = """
        SELECT id, game_id, white_player_id, black_player_id, status, created_at, updated_at
        FROM matches
        WHERE id = %s
    """
    if for_update:
        query += " FOR UPDATE"
    with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
        cursor.execute(query, (match_id,))
        return cursor.fetchone()


def fetch_match_moves(
    connection: psycopg.Connection,
    game_id: uuid.UUID,
    after_ply: int = 0,
) -> list[dict[str, Any]]:
    with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
        cursor.execute(
            """
            SELECT %s::uuid AS match_id, game_id, ply, move_uci, player_id, created_at
            FROM game_moves
            WHERE game_id = %s AND ply > %s
            ORDER BY ply ASC
            """,
            (uuid.UUID(int=0), game_id, after_ply),
        )
        rows = list(cursor.fetchall())
    return rows


def fetch_match_moves_for_match(
    connection: psycopg.Connection,
    match_id: uuid.UUID,
    game_id: uuid.UUID,
    after_ply: int = 0,
) -> list[dict[str, Any]]:
    with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
        cursor.execute(
            """
            SELECT %s::uuid AS match_id, game_id, ply, move_uci, player_id, created_at
            FROM game_moves
            WHERE game_id = %s AND ply > %s
            ORDER BY ply ASC
            """,
            (match_id, game_id, after_ply),
        )
        return list(cursor.fetchall())


def current_match_state(
    connection: psycopg.Connection,
    match_id: uuid.UUID,
    player_id: uuid.UUID | None = None,
) -> dict[str, Any]:
    match_row = fetch_match_row(connection, match_id=match_id)
    if match_row is None:
        raise HTTPException(status_code=404, detail="Match not found.")

    moves = fetch_match_moves_for_match(connection, match_id, match_row["game_id"], after_ply=0)
    latest_ply = moves[-1]["ply"] if moves else 0
    return {
        "match_id": match_row["id"],
        "game_id": match_row["game_id"],
        "status": match_row["status"],
        "white_player_id": match_row["white_player_id"],
        "black_player_id": match_row["black_player_id"],
        "your_color": color_for_player(match_row, player_id) if player_id else None,
        "latest_ply": latest_ply,
        "next_turn": next_turn_for_ply(latest_ply),
        "moves": moves,
    }


def ticket_response_for_row(
    connection: psycopg.Connection,
    ticket_row: dict[str, Any],
) -> dict[str, Any]:
    assigned_color = None
    if ticket_row["match_id"] is not None:
        match_row = fetch_match_row(connection, ticket_row["match_id"])
        if match_row is not None:
            assigned_color = color_for_player(match_row, ticket_row["player_id"])

    return {
        "ticket_id": ticket_row["id"],
        "player_id": ticket_row["player_id"],
        "status": ticket_row["status"],
        "match_id": ticket_row["match_id"],
        "assigned_color": assigned_color,
        "heartbeat_at": ticket_row["heartbeat_at"],
        "expires_at": ticket_row["expires_at"],
        "poll_after_ms": 1000,
    }


def ensure_player_ticket(
    connection: psycopg.Connection,
    player_id: uuid.UUID,
) -> dict[str, Any]:
    with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
        cursor.execute(
            """
            SELECT id, player_id, status, heartbeat_at, expires_at, match_id, created_at, updated_at
            FROM tickets
            WHERE player_id = %s AND status IN ('queued', 'matched')
            ORDER BY created_at DESC
            LIMIT 1
            FOR UPDATE
            """,
            (player_id,),
        )
        ticket_row = cursor.fetchone()

        if ticket_row is not None:
            if ticket_row["status"] == "queued":
                expires_at = ticket_expiry_from_now()
                cursor.execute(
                    """
                    UPDATE tickets
                    SET heartbeat_at = NOW(), expires_at = %s, updated_at = NOW()
                    WHERE id = %s
                    RETURNING id, player_id, status, heartbeat_at, expires_at, match_id, created_at, updated_at
                    """,
                    (expires_at, ticket_row["id"]),
                )
                ticket_row = cursor.fetchone()
            return ticket_row

        ticket_id = uuid.uuid4()
        expires_at = ticket_expiry_from_now()
        cursor.execute(
            """
            INSERT INTO tickets (id, player_id, status, heartbeat_at, expires_at)
            VALUES (%s, %s, 'queued', NOW(), %s)
            ON CONFLICT DO NOTHING
            RETURNING id, player_id, status, heartbeat_at, expires_at, match_id, created_at, updated_at
            """,
            (ticket_id, player_id, expires_at),
        )
        inserted_row = cursor.fetchone()
        if inserted_row is not None:
            return inserted_row

        cursor.execute(
            """
            SELECT id, player_id, status, heartbeat_at, expires_at, match_id, created_at, updated_at
            FROM tickets
            WHERE player_id = %s AND status IN ('queued', 'matched')
            ORDER BY created_at DESC
            LIMIT 1
            FOR UPDATE
            """,
            (player_id,),
        )
        existing_row = cursor.fetchone()
        if existing_row is None:
            raise HTTPException(status_code=409, detail="Could not establish a matchmaking ticket.")
        return existing_row


def try_pair_ticket(
    connection: psycopg.Connection,
    ticket_row: dict[str, Any],
) -> dict[str, Any]:
    if ticket_row["status"] != "queued":
        return ticket_row

    with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
        cursor.execute(
            """
            SELECT id, player_id, status, heartbeat_at, expires_at, match_id, created_at, updated_at
            FROM tickets
            WHERE status = 'queued'
              AND match_id IS NULL
              AND expires_at >= NOW()
              AND player_id <> %s
            ORDER BY created_at ASC
            LIMIT 1
            FOR UPDATE SKIP LOCKED
            """,
            (ticket_row["player_id"],),
        )
        other_ticket = cursor.fetchone()

        if other_ticket is None:
            return ticket_row

        if other_ticket["player_id"] == ticket_row["player_id"]:
            return ticket_row

        current_created_at = ticket_row["created_at"]
        other_created_at = other_ticket["created_at"]
        white_player_id = other_ticket["player_id"] if other_created_at <= current_created_at else ticket_row["player_id"]
        black_player_id = ticket_row["player_id"] if white_player_id == other_ticket["player_id"] else other_ticket["player_id"]

        match_id = uuid.uuid4()
        game_id = create_game_record(connection=connection)
        cursor.execute(
            """
            INSERT INTO matches (id, game_id, white_player_id, black_player_id, status)
            VALUES (%s, %s, %s, %s, 'active')
            """,
            (match_id, game_id, white_player_id, black_player_id),
        )
        cursor.execute(
            """
            UPDATE tickets
            SET status = 'matched', match_id = %s, updated_at = NOW(), expires_at = %s
            WHERE id IN (%s, %s)
            """,
            (match_id, ticket_expiry_from_now(), ticket_row["id"], other_ticket["id"]),
        )

    refreshed_ticket = fetch_ticket_row(connection, ticket_row["id"], for_update=False)
    if refreshed_ticket is None:
        raise HTTPException(status_code=500, detail="Could not refresh matched ticket.")
    return refreshed_ticket


def enqueue_player_for_matchmaking(player_id: uuid.UUID) -> dict[str, Any]:
    with connect_postgres() as connection, connection.transaction():
        ensure_schema_ready(connection)
        expire_stale_tickets(connection)
        ticket_row = ensure_player_ticket(connection, player_id)
        ticket_row = try_pair_ticket(connection, ticket_row)
        return ticket_response_for_row(connection, ticket_row)


def heartbeat_matchmaking_ticket(ticket_id: uuid.UUID, player_id: uuid.UUID) -> dict[str, Any]:
    with connect_postgres() as connection, connection.transaction():
        ensure_schema_ready(connection)
        expire_stale_tickets(connection)
        ticket_row = fetch_ticket_row(connection, ticket_id=ticket_id, player_id=player_id, for_update=True)
        if ticket_row is None:
            raise HTTPException(status_code=404, detail="Ticket not found.")
        if ticket_row["status"] in {"cancelled", "expired"}:
            return ticket_response_for_row(connection, ticket_row)

        expires_at = ticket_expiry_from_now()
        with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
            cursor.execute(
                """
                UPDATE tickets
                SET heartbeat_at = NOW(), expires_at = %s, updated_at = NOW()
                WHERE id = %s
                RETURNING id, player_id, status, heartbeat_at, expires_at, match_id, created_at, updated_at
                """,
                (expires_at, ticket_id),
            )
            ticket_row = cursor.fetchone()
        ticket_row = try_pair_ticket(connection, ticket_row)
        return ticket_response_for_row(connection, ticket_row)


def get_matchmaking_ticket(ticket_id: uuid.UUID, player_id: uuid.UUID | None = None) -> dict[str, Any]:
    with connect_postgres() as connection, connection.transaction():
        ensure_schema_ready(connection)
        expire_stale_tickets(connection)
        ticket_row = fetch_ticket_row(connection, ticket_id=ticket_id, player_id=player_id, for_update=False)
        if ticket_row is None:
            raise HTTPException(status_code=404, detail="Ticket not found.")
        return ticket_response_for_row(connection, ticket_row)


def cancel_matchmaking_ticket(ticket_id: uuid.UUID, player_id: uuid.UUID) -> dict[str, Any]:
    with connect_postgres() as connection, connection.transaction():
        ensure_schema_ready(connection)
        ticket_row = fetch_ticket_row(connection, ticket_id=ticket_id, player_id=player_id, for_update=True)
        if ticket_row is None:
            raise HTTPException(status_code=404, detail="Ticket not found.")
        if ticket_row["status"] == "matched":
            raise HTTPException(status_code=409, detail="Matched tickets cannot be cancelled.")

        with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
            cursor.execute(
                """
                UPDATE tickets
                SET status = 'cancelled', updated_at = NOW()
                WHERE id = %s
                RETURNING id, player_id, status, heartbeat_at, expires_at, match_id, created_at, updated_at
                """,
                (ticket_id,),
            )
            cancelled_row = cursor.fetchone()
        return ticket_response_for_row(connection, cancelled_row)


def build_conflict_detail(
    connection: psycopg.Connection,
    match_id: uuid.UUID,
    player_id: uuid.UUID,
    message: str,
) -> dict[str, Any]:
    return {
        "message": message,
        "current_state": current_match_state(connection, match_id, player_id),
    }


def get_match_state_record(match_id: uuid.UUID, player_id: uuid.UUID | None = None) -> dict[str, Any]:
    with connect_postgres() as connection, connection.transaction():
        ensure_schema_ready(connection)
        return current_match_state(connection, match_id, player_id)


def record_queue_match_move(
    match_id: uuid.UUID,
    player_id: uuid.UUID,
    ply: int,
    move_uci: str,
) -> dict[str, Any]:
    with connect_postgres() as connection, connection.transaction():
        ensure_schema_ready(connection)
        match_row = fetch_match_row(connection, match_id=match_id, for_update=True)
        if match_row is None:
            raise HTTPException(status_code=404, detail="Match not found.")
        if match_row["status"] != "active":
            raise HTTPException(status_code=409, detail="Match is not active.")

        player_color = color_for_player(match_row, player_id)
        if player_color is None:
            raise HTTPException(status_code=403, detail="Player is not part of this match.")

        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT COALESCE(MAX(ply), 0) FROM game_moves WHERE game_id = %s",
                (match_row["game_id"],),
            )
            latest_ply = int(cursor.fetchone()[0])

        expected_ply = latest_ply + 1
        expected_turn = next_turn_for_ply(latest_ply)

        if player_color != expected_turn:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=build_conflict_detail(
                    connection,
                    match_id,
                    player_id,
                    f"It is {expected_turn}'s turn.",
                ),
            )

        if ply != expected_ply:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=build_conflict_detail(
                    connection,
                    match_id,
                    player_id,
                    f"Expected ply {expected_ply}, received {ply}.",
                ),
            )

        try:
            with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
                cursor.execute(
                    """
                    INSERT INTO game_moves (game_id, ply, move_uci, player_id)
                    VALUES (%s, %s, %s, %s)
                    RETURNING %s::uuid AS match_id, game_id, ply, move_uci, player_id, created_at
                    """,
                    (match_row["game_id"], ply, move_uci, player_id, match_id),
                )
                move_row = cursor.fetchone()
                cursor.execute(
                    "UPDATE matches SET updated_at = NOW() WHERE id = %s",
                    (match_id,),
                )
        except psycopg.errors.UniqueViolation:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=build_conflict_detail(
                    connection,
                    match_id,
                    player_id,
                    "This ply is already recorded on the server.",
                ),
            ) from None

    return move_row


def get_queue_match_moves(
    match_id: uuid.UUID,
    after_ply: int,
    player_id: uuid.UUID | None = None,
) -> dict[str, Any]:
    with connect_postgres() as connection, connection.transaction():
        ensure_schema_ready(connection)
        match_state = current_match_state(connection, match_id, player_id)
        filtered_moves = [move for move in match_state["moves"] if move["ply"] > after_ply]
        return {
            "match_id": match_state["match_id"],
            "game_id": match_state["game_id"],
            "latest_ply": match_state["latest_ply"],
            "next_turn": match_state["next_turn"],
            "moves": filtered_moves,
        }


@app.get("/health/ping")
def health_ping() -> dict[str, Any]:
    postgres_ok, postgres_message = ping_postgres()
    status_code = 200 if postgres_ok else 503
    payload = {
        "ok": postgres_ok,
        "messages": [
            "Server ping successful",
            postgres_message,
        ],
    }
    return JSONResponse(content=payload, status_code=status_code)


@app.post("/v1/games")
def create_game() -> dict[str, str]:
    try:
        game_id = create_game_record()
        return {"game_id": str(game_id)}
    except Exception as exc:  # pragma: no cover - exercised in integration
        logger.exception("Could not create game log in Postgres")
        raise HTTPException(
            status_code=503,
            detail=f"Could not create game log in Postgres: {exc}",
        ) from exc


@app.post("/v1/games/{game_id}/moves", response_model=GameMoveRecord)
def record_game_move(game_id: uuid.UUID, payload: GameMoveRequest) -> dict[str, Any]:
    try:
        return save_game_move(game_id, payload.ply, payload.move_uci)
    except HTTPException:
        raise
    except Exception as exc:  # pragma: no cover - exercised in integration
        logger.exception("Could not record game move in Postgres")
        raise HTTPException(
            status_code=503,
            detail=f"Could not record game move in Postgres: {exc}",
        ) from exc


@app.get("/v1/games/{game_id}/moves")
def get_game_moves(game_id: uuid.UUID) -> dict[str, Any]:
    try:
        return {"game_id": str(game_id), "moves": fetch_game_moves(game_id)}
    except Exception as exc:  # pragma: no cover - exercised in integration
        logger.exception("Could not load game moves from Postgres")
        raise HTTPException(
            status_code=503,
            detail=f"Could not load game moves from Postgres: {exc}",
        ) from exc


@app.post("/v1/matchmaking/enqueue", response_model=TicketResponse)
def enqueue_matchmaking(payload: EnqueueMatchmakingRequest) -> dict[str, Any]:
    return enqueue_player_for_matchmaking(payload.player_id)


@app.post("/v1/matchmaking/{ticket_id}/heartbeat", response_model=TicketResponse)
def heartbeat_matchmaking(
    ticket_id: uuid.UUID,
    payload: MatchmakingTicketActionRequest,
) -> dict[str, Any]:
    return heartbeat_matchmaking_ticket(ticket_id, payload.player_id)


@app.get("/v1/matchmaking/{ticket_id}", response_model=TicketResponse)
def get_matchmaking_status(
    ticket_id: uuid.UUID,
    player_id: uuid.UUID | None = Query(default=None),
) -> dict[str, Any]:
    return get_matchmaking_ticket(ticket_id, player_id)


@app.delete("/v1/matchmaking/{ticket_id}", response_model=TicketResponse)
def delete_matchmaking_ticket(
    ticket_id: uuid.UUID,
    player_id: uuid.UUID = Query(...),
) -> dict[str, Any]:
    return cancel_matchmaking_ticket(ticket_id, player_id)


@app.get("/v1/matches/{match_id}/state", response_model=MatchStateResponse)
def get_match_state(
    match_id: uuid.UUID,
    player_id: uuid.UUID | None = Query(default=None),
) -> dict[str, Any]:
    return get_match_state_record(match_id, player_id)


@app.post("/v1/matches/{match_id}/moves", response_model=MatchMoveRecord)
def post_match_move(
    match_id: uuid.UUID,
    payload: QueueMatchMoveRequest,
) -> dict[str, Any]:
    return record_queue_match_move(match_id, payload.player_id, payload.ply, payload.move_uci)


@app.get("/v1/matches/{match_id}/moves", response_model=MatchMovesResponse)
def get_match_moves(
    match_id: uuid.UUID,
    after_ply: int = Query(default=0, ge=0),
    player_id: uuid.UUID | None = Query(default=None),
) -> dict[str, Any]:
    return get_queue_match_moves(match_id, after_ply, player_id)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8080")),
        reload=False,
    )
