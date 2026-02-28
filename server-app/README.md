# server-app

Backend skeleton owned by Person 1.

## Scope

- FastAPI service scaffold only
- Health ping endpoint for app/server/Postgres verification
- No business logic yet

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
