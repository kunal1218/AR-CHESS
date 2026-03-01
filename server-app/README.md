# server-app

Backend owned by Person 1.

## Scope

- FastAPI service for health checks and match move logging
- Postgres-backed `games` and `game_moves` tables
- UCI move notation for Stockfish-compatible consumers

## Local run

1. Create a virtual environment.
2. Install `requirements.txt`.
3. Run `python3 main.py`.

## Environment

- Copy `.env.example` to `.env` for local development if needed.
- Use `.env.railway.example` as the Railway deployment template.
- Prefer `DATABASE_URL` on Railway. The app falls back to `POSTGRES_*` variables if needed.

## Health ping

- `GET /health/ping`
- Returns:
  - `Server ping successful`
  - `Postgres ping successful`

## Match move log

- `POST /v1/games`
  - Creates a new server-backed game log and returns `game_id`
- `POST /v1/games/{game_id}/moves`
  - Request body:
    - `ply`
    - `move_uci`
  - `move_uci` must use UCI notation like `e2e4`, `e1g1`, or `e7e8q`
- `GET /v1/games/{game_id}/moves`
  - Returns the ordered move log for that game

Moves are stored in Postgres table `game_moves`, keyed by `game_id` and `ply`.
