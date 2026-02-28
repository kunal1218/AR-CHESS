# ar-chess

Monorepo for the AR Chess platform with the existing server and a native iOS app.

## Ownership boundaries

- `server-app/`: Person 1 owns the backend application.
- `mobile/`: archived React Native client kept for reference while the active iOS app runs natively from Xcode.
- `shared/`: Shared integration boundary for API contracts and DTOs only.
- `infra/`: Docker Compose, environment templates, and operational scripts.
- `docs/`: Architecture and workflow documentation.
- `legacy/old-client/`: archived Android-native client kept only for reference.
- `ios/`: active native iOS app with SwiftUI screens and RealityKit/ARKit runtime.

## Quick start

- Server app: `cd server-app && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt && python3 main.py`
- Native iOS app: `open ios/ARChess.xcworkspace`
- Compose stack: `docker-compose up --build` from the repo root, or `docker compose --env-file infra/.env.example -f infra/docker-compose.yml up --build`

## iPhone + Xcode

- Open `ios/ARChess.xcworkspace` in Xcode.
- Run the `ARChess` scheme on an iPhone for native AR.
- The app now launches native SwiftUI screens for `Join`, `Create`, `Lobby / Loading`, and the native AR sandbox.
- `mobile/` is no longer the active iOS runtime path.

The native iOS UI does not require the server to be running. If you wire networking later, use your Mac's LAN IP instead of `localhost`.
