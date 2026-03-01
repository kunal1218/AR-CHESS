import os
import re
import uuid
from datetime import datetime

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from dotenv import load_dotenv
from pydantic import BaseModel, Field, field_validator
import psycopg
import uvicorn

load_dotenv()

DEFAULT_POSTGRES_PORT = 5432
UCI_MOVE_PATTERN = re.compile(r"^[a-h][1-8][a-h][1-8][nbrq]?$")
SCHEMA_READY = False


app = FastAPI(
    title="AR Chess Server",
    description="Empty FastAPI scaffold for the AR Chess backend.",
    version="0.1.0",
)


class CreateGameResponse(BaseModel):
    game_id: str


class RecordMoveRequest(BaseModel):
    ply: int = Field(ge=1)
    move_uci: str = Field(min_length=4, max_length=5)

    @field_validator("move_uci")
    @classmethod
    def validate_move_uci(cls, value: str) -> str:
        normalized = value.strip().lower()
        if not UCI_MOVE_PATTERN.fullmatch(normalized):
            raise ValueError(
                "move_uci must use UCI notation like e2e4, e1g1, or e7e8q"
            )
        return normalized


class GameMoveRecord(BaseModel):
    game_id: str
    ply: int
    move_uci: str
    created_at: datetime


class GameMoveListResponse(BaseModel):
    game_id: str
    moves: list[GameMoveRecord]


def get_postgres_dsn() -> str:
    database_url = os.getenv("DATABASE_URL", "").strip()
    if database_url:
        return database_url

    host = os.getenv("POSTGRES_HOST", "localhost")
    port = os.getenv("POSTGRES_PORT", str(DEFAULT_POSTGRES_PORT))
    database = os.getenv("POSTGRES_DB", "archess")
    user = os.getenv("POSTGRES_USER", "archess")
    password = os.getenv("POSTGRES_PASSWORD", "archess")

    return f"postgresql://{user}:{password}@{host}:{port}/{database}"


def connect_postgres() -> psycopg.Connection:
    return psycopg.connect(get_postgres_dsn(), connect_timeout=5)


def ensure_move_log_schema() -> None:
    global SCHEMA_READY

    if SCHEMA_READY:
        return

    with connect_postgres() as connection:
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
                    ply BIGINT NOT NULL CHECK (ply >= 1),
                    move_uci TEXT NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    UNIQUE (game_id, ply)
                )
                """
            )
            cursor.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_game_moves_game_id_created_at
                ON game_moves (game_id, created_at)
                """
            )
        connection.commit()

    SCHEMA_READY = True


def create_game_record() -> uuid.UUID:
    ensure_move_log_schema()
    game_id = uuid.uuid4()

    with connect_postgres() as connection:
        with connection.cursor() as cursor:
            cursor.execute("INSERT INTO games (id) VALUES (%s)", (game_id,))
        connection.commit()

    return game_id


def save_game_move(game_id: uuid.UUID, ply: int, move_uci: str) -> dict[str, object]:
    ensure_move_log_schema()

    with connect_postgres() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                "INSERT INTO games (id) VALUES (%s) ON CONFLICT (id) DO NOTHING",
                (game_id,),
            )
            cursor.execute(
                """
                INSERT INTO game_moves (game_id, ply, move_uci)
                VALUES (%s, %s, %s)
                ON CONFLICT (game_id, ply)
                DO UPDATE SET move_uci = EXCLUDED.move_uci
                RETURNING game_id::text, ply, move_uci, created_at
                """,
                (game_id, ply, move_uci),
            )
            row = cursor.fetchone()
        connection.commit()

    if row is None:
        raise RuntimeError("Move insert failed to return a row")

    stored_game_id, stored_ply, stored_move_uci, created_at = row
    return {
        "game_id": stored_game_id,
        "ply": stored_ply,
        "move_uci": stored_move_uci,
        "created_at": created_at,
    }


def fetch_game_moves(game_id: uuid.UUID) -> list[dict[str, object]]:
    ensure_move_log_schema()

    with connect_postgres() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT game_id::text, ply, move_uci, created_at
                FROM game_moves
                WHERE game_id = %s
                ORDER BY ply ASC
                """,
                (game_id,),
            )
            rows = cursor.fetchall()

    return [
        {
            "game_id": stored_game_id,
            "ply": stored_ply,
            "move_uci": stored_move_uci,
            "created_at": created_at,
        }
        for stored_game_id, stored_ply, stored_move_uci, created_at in rows
    ]


def ping_postgres() -> tuple[bool, str]:
    try:
        with connect_postgres() as connection:
            with connection.cursor() as cursor:
                cursor.execute("SELECT 1")
                cursor.fetchone()

        return True, "Postgres ping successful"
    except Exception as exc:
        return False, f"Postgres ping failed: {exc}"


@app.get("/health/ping")
def health_ping() -> JSONResponse:
    postgres_ok, postgres_message = ping_postgres()
    payload = {
        "ok": postgres_ok,
        "messages": [
            "Server ping successful",
            postgres_message,
        ],
        "checks": {
            "server": {
                "ok": True,
                "message": "Server ping successful",
            },
            "postgres": {
                "ok": postgres_ok,
                "message": postgres_message,
            },
        },
    }

    return JSONResponse(status_code=200 if postgres_ok else 503, content=payload)


@app.post("/v1/games", response_model=CreateGameResponse)
def create_game() -> CreateGameResponse:
    try:
        game_id = create_game_record()
    except Exception as exc:
        raise HTTPException(
            status_code=503,
            detail=f"Could not create game log in Postgres: {exc}",
        ) from exc

    return CreateGameResponse(game_id=str(game_id))


@app.post("/v1/games/{game_id}/moves", response_model=GameMoveRecord)
def record_game_move(
    game_id: uuid.UUID,
    payload: RecordMoveRequest,
) -> GameMoveRecord:
    try:
        move = save_game_move(game_id=game_id, ply=payload.ply, move_uci=payload.move_uci)
    except Exception as exc:
        raise HTTPException(
            status_code=503,
            detail=f"Could not write move log to Postgres: {exc}",
        ) from exc

    return GameMoveRecord.model_validate(move)


@app.get("/v1/games/{game_id}/moves", response_model=GameMoveListResponse)
def get_game_moves(game_id: uuid.UUID) -> GameMoveListResponse:
    try:
        moves = [GameMoveRecord.model_validate(item) for item in fetch_game_moves(game_id)]
    except Exception as exc:
        raise HTTPException(
            status_code=503,
            detail=f"Could not load move log from Postgres: {exc}",
        ) from exc

    return GameMoveListResponse(game_id=str(game_id), moves=moves)


if __name__ == "__main__":
    port = int(os.getenv("PORT", "8000"))
    uvicorn.run("main:app", host="0.0.0.0", port=port, reload=True)
