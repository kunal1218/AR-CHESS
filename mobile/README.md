# mobile

Expo-managed React Native client for AR Chess. iOS + Expo Go is the primary development path.

## Local setup

1. Install dependencies.

```bash
npm install
```

2. Start Expo.

```bash
npx expo start
```

3. Open Expo Go on your iPhone and scan the QR code from the terminal.

## Railway ping setup

1. Copy `.env.example` to `.env.local`.
2. Set `EXPO_PUBLIC_API_BASE_URL` to your Railway backend URL.

```bash
EXPO_PUBLIC_API_BASE_URL=https://your-railway-service.up.railway.app
```

3. Tap `Ping Server + Postgres` on the landing screen.
4. If both checks succeed, the app shows:
   - `Server ping successful`
   - `Postgres ping successful`

## Notes

- The phone and your Mac must be on the same Wi-Fi network.
- The landing screen shows a chessboard-themed background with `Join` and `Create`.
- Either action opens Lobby, then `Open Game Sandbox` mounts the shared `ar-client` runtime and board.
- `mobile/` remains the host shell; chess engine + AR board logic live in `../ar-client`.
- The app works without the server running.
- `EXPO_PUBLIC_API_BASE_URL` is used by the landing-screen health ping button.
