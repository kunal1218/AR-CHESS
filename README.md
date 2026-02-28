# ar-chess

Monorepo for the AR Chess platform with the existing server and an Expo-managed React Native mobile app.

## Ownership boundaries

- `server-app/`: Person 1 owns the backend application.
- `mobile/`: Person 2 owns the Expo Go mobile client.
- `shared/`: Shared integration boundary for API contracts and DTOs only.
- `infra/`: Docker Compose, environment templates, and operational scripts.
- `docs/`: Architecture and workflow documentation.
- `legacy/old-client/`: archived pre-Expo native client kept only for reference.

## Quick start

- Server app: `cd server-app && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt && python3 main.py`
- Mobile app: `cd mobile && npm install && npx expo start`
- Compose stack: `docker-compose up --build` from the repo root, or `docker compose --env-file infra/.env.example -f infra/docker-compose.yml up --build`

## iPhone + Expo Go

- Install Expo Go on your iPhone.
- Run `cd mobile && npm install && npx expo start`.
- Scan the Expo QR code from the terminal with Expo Go on the same Wi-Fi network.
- The landing page includes `Join` and `Create`, then opens a placeholder lobby that says `AR experience opens next (TODO)`.
- Set `EXPO_PUBLIC_API_BASE_URL` in `mobile/.env.local` to your Railway backend URL if you want to use the `Ping Server + Postgres` button.
- Use `.env.railway.example` as the repo-level Railway variable template.

The mobile UI does not require the server to be running. If you wire networking later, use your Mac's LAN IP instead of `localhost`.
