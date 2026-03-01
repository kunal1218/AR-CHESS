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

## Stockfish integration

- The active engine integration is native iOS-only and lives in `ios/ARChess/AppDelegate.swift`.
- Stockfish runs as one long-lived local session per AR game. The controller now enforces a strict UCI lifecycle:
  - `uci` -> wait for `uciok`
  - set safe mobile options (`Threads=1`, `Hash=16`, `Ponder=false`)
  - `isready` -> wait for `readyok`
  - before each search: `stop` if needed, `isready`, optional `ucinewgame`, `position fen ...`, then `go movetime 80`
- Searches are time-based by default instead of depth-based for better real-time behavior in AR.
- Every request carries diagnostics: request id, FEN hash, recent commands sent, recent engine output, and the last controller state.

### Debugging in app

- In the native AR overlay, use `Analyze current position` to manually run a local Stockfish request against the current board without making a move.
- The overlay shows:
  - next best move
  - white eval
  - black eval
  - last analysis duration
- If Stockfish fails, the UI surfaces the last controller stage and error text instead of silently timing out.

### Repro harness

- Run the no-AR harness from the existing JS package root:
  - `cd mobile && npm run test:stockfish`
- The harness uses the exact bundled engine artifact from `ios/ARChess/Stockfish/stockfish-nnue-16-single.js`.
- It runs 10 sample FENs at `movetime` `50/100/200ms`, validates returned `bestmove`, enforces hard timeouts, and dumps actionable diagnostics on failure.
