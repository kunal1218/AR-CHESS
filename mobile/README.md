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

## Notes

- The phone and your Mac must be on the same Wi-Fi network.
- The landing screen shows a chessboard-themed background with `Join` and `Create`.
- Either action opens Lobby, then `Open Game Sandbox` mounts the shared `ar-client` runtime and board.
- `mobile/` remains the host shell; chess engine + AR board logic live in `../ar-client`.
- The app works without the server running.
- `EXPO_PUBLIC_API_BASE_URL` is kept as an optional future hook in `.env.example` if you want to prepare later networking.

## Local package resolution

- `ar-client` is linked as a local dependency (`file:../ar-client`).
- If Metro fails with `Unable to resolve module ar-client`, run:

```bash
npm install
npx expo start -c
```
