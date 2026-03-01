# server-app

Backend owned by Person 1.

## Scope

- FastAPI service for health checks, pass-and-play move logging, and queue matchmaking
- Postgres-backed `games`, `game_moves`, `tickets`, and `matches` tables
- UCI move notation for Stockfish-compatible consumers

## Local run

1. Create a virtual environment.
2. Install `requirements.txt`.
3. Run `python3 main.py`.

## Environment

- Copy `.env.example` to `.env` for local development if needed.
- Use `.env.railway.example` as the Railway deployment template.
- Prefer `DATABASE_URL` on Railway private networking.
- `DATABASE_PRIVATE_URL` and `DATABASE_PUBLIC_URL` are also accepted if that is how your service variables are wired.
- The app also supports Railway `PG*` variables and finally falls back to `POSTGRES_*` variables.

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

## Queue matchmaking

- `POST /v1/matchmaking/enqueue`
  - Request body:
    - `player_id`
  - Creates or refreshes a queue ticket for the device.
- `POST /v1/matchmaking/{ticket_id}/heartbeat`
  - Request body:
    - `player_id`
  - Extends queue TTL and can complete pairing if another player is waiting.
- `GET /v1/matchmaking/{ticket_id}?player_id=...`
  - Returns queue status, optional `match_id`, and optional assigned color.
- `DELETE /v1/matchmaking/{ticket_id}?player_id=...`
  - Cancels a waiting ticket.

## Synced match state

- `GET /v1/matches/{match_id}/state?player_id=...`
  - Returns the authoritative game state, assigned color, current move list, and next turn.
- `POST /v1/matches/{match_id}/moves`
  - Request body:
    - `player_id`
    - `ply`
    - `move_uci`
  - Enforces:
    - player membership
    - player color turn order
    - one move per ply
  - Returns `409` with current server state if the client is stale or another move already owns that ply.
- `GET /v1/matches/{match_id}/moves?after_ply=...&player_id=...`
  - Returns ordered moves after the requested ply, plus `latest_ply` and `next_turn`.

Matchmaking uses Postgres transactions and `FOR UPDATE SKIP LOCKED` so two queue tickets cannot pair with the same opponent concurrently.
