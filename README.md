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
- For Gemini hints and narration, configure `ARChessAPIBaseURL` for the iOS app and set `GEMINI_API_KEY` only on the backend (`server-app/.env`).
- For local low-latency Piper piece voices, configure `ARChessPiperAPIBaseURL` to your Mac's LAN URL for `server-app` while keeping `ARChessAPIBaseURL` on Railway.
- Gemini hints currently run through the backend Gemini Live session. Keep `GEMINI_LIVE_MODEL` on a Live-capable model such as `models/gemini-2.5-flash-native-audio-preview-12-2025`; Gemini 3 models are not currently supported on the Live API.

The native iOS UI does not require the server for local board play, but Gemini hints now require the server. Use your Mac's LAN IP instead of `localhost` when running on iPhone. The app can now split traffic so Gemini uses Railway and Piper piece voices use your local Mac backend.

## Reproducible iOS testing

Use this flow when you want a clean, repeatable Xcode setup from a fresh checkout.

### Prerequisites

- macOS with the full Xcode app installed, not just Command Line Tools.
- An iPhone for AR gameplay testing. The Simulator is fine for menu/build smoke tests, but board placement, camera, fishing, and full AR runtime need a real device.
- Node/npm available on your Mac, because the iOS workspace still resolves Expo/React Native pods from `mobile/`.
- CocoaPods installed.

### One-time local setup

1. Point developer tools at full Xcode:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

2. Install the JS dependencies used by the Podfile:

```bash
cd mobile
npm install
```

3. Install iOS pods:

```bash
cd ../ios
pod install
```

4. Open the workspace, not the project:

```bash
open ARChess.xcworkspace
```

### Xcode project setup

1. In Xcode, choose the `ARChess` scheme.
2. Open the `ARChess` target -> `Signing & Capabilities`.
3. Select your Apple Development team.
4. If signing complains about the default bundle id, replace `com.example.archess` with your own unique bundle identifier.
5. Use the default `Info.plist` values unless you intentionally want to point the app at a different backend:
   - `ARChessAPIBaseURL`
   - `ARChessPiperAPIBaseURL`

### Recommended smoke-test flow

There is currently no separate XCTest target in this workspace. The repeatable test flow is a build-and-run smoke test through Xcode.

#### Simulator smoke test

Use this to verify the app still builds and the SwiftUI shell launches.

1. Select an iPhone simulator in Xcode.
2. Press `Cmd+B` to build.
3. Press `Cmd+R` to run.
4. Verify the main menu loads and you can open:
   - `Play`
   - `Settings`
   - `Cosmetics`

#### Real-device AR smoke test

Use this for anything involving AR, Stockfish gameplay, fishing, camera, microphone, or world-space UI.

1. Connect an iPhone and select it as the run destination.
2. Press `Cmd+R`.
3. Grant camera and microphone permission if prompted.
4. Wait for the board to appear.
5. Verify these core paths:
   - `Pass and Play`: place the board and make one legal move.
   - `Play vs Stockfish`: make one legal move and confirm Stockfish replies.
   - `Settings`: toggle simplified HUD, coach selection, and `VR Chess Label`.
   - `Cosmetics`: open the creator room and verify the preview loads.

### Useful reset steps

If Xcode gets into a bad state, use this order:

1. `Product -> Clean Build Folder`
2. Quit Xcode
3. Re-run:

```bash
cd mobile && npm install
cd ../ios && pod install
open ARChess.xcworkspace
```

If `xcodebuild` says it requires Xcode but the active developer directory points to Command Line Tools, re-run:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

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
- When it becomes the local player's turn, the app now prefetches a Gemini hint in the background from the current Stockfish best move.
- Tap `Hint` to reveal the cached beginner-friendly hint. If prefetch is still running, the UI shows a short loading state instead of the raw move.
- The overlay shows:
  - Gemini hint status
  - Gemini Live connection state (`DISCONNECTED`, `CONNECTING`, `CONNECTED`, `ERROR`) in Gemini debug
  - white eval
  - black eval
  - last analysis duration
- If Stockfish fails, the UI surfaces the last controller stage and error text instead of silently timing out.

### Repro harness

- Run the no-AR harness from the existing JS package root:
  - `cd mobile && npm run test:stockfish`
- The harness uses the exact bundled engine artifact from `ios/ARChess/Stockfish/stockfish-nnue-16-single.js`.
- It runs 10 sample FENs at `movetime` `50/100/200ms`, validates returned `bestmove`, enforces hard timeouts, and dumps actionable diagnostics on failure.
