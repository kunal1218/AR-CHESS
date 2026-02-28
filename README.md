# ar-chess

Monorepo scaffold for parallel development of the AR Chess platform.

## Ownership boundaries

- `server-app/`: Person 1 owns the backend application.
- `ar-client/`: Person 2 owns the Android AR client.
- `shared/`: Shared integration boundary for API contracts and DTOs only.
- `infra/`: Docker Compose, environment templates, and operational scripts.
- `docs/`: Architecture and workflow documentation.

## Quick start

- Server app: `cd server-app && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt && python3 main.py`
- Compose stack: `docker-compose up --build` from the repo root, or `docker compose --env-file infra/.env.example -f infra/docker-compose.yml up --build`
- Android client: open `ar-client/` in Android Studio and run the `app` configuration after setting up the Android SDK.
