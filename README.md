# ar-chess

Monorepo for the AR Chess platform with a FastAPI backend and an Expo-managed React Native mobile client.

## Ownership boundaries

- `server-app/`: Person 1 owns the backend application.
- `mobile/`: Person 2 owns the Expo Go mobile client.
- `shared/`: Shared integration boundary for API contracts and DTOs only.
- `infra/`: Docker Compose, environment templates, and operational scripts.
- `docs/`: Architecture and workflow documentation.
- `legacy/native-client/`: archived Android-native scaffold kept only for reference.

## Quick start

- Server app: `cd server-app && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt && python3 main.py`
- Mobile app: `cd mobile && cp .env.example .env.local && npm install && npm run start`
- Compose stack: `docker-compose up --build` from the repo root, or `docker compose --env-file infra/.env.example -f infra/docker-compose.yml up --build`

## iPhone + Expo Go

- Install Expo Go on your iPhone.
- Set `EXPO_PUBLIC_API_BASE_URL` in `mobile/.env.local` to your Mac's LAN IP, for example `http://192.168.1.20:8000`.
- Start the server on `0.0.0.0:8000` and run `make mobile-dev`.
- Scan the Expo QR code from the terminal with Expo Go on the same Wi-Fi network.

`localhost` will not work from the phone. Use your Mac's LAN IP instead.
