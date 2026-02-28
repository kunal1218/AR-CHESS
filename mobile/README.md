# mobile

Expo-managed React Native client for AR Chess. iOS + Expo Go is the primary development path.

## Local setup

1. Install dependencies.

```bash
npm install
```

2. Copy the env template.

```bash
cp .env.example .env.local
```

3. Set `EXPO_PUBLIC_API_BASE_URL` in `.env.local` to your Mac's LAN IP, not `localhost`.

```bash
EXPO_PUBLIC_API_BASE_URL=http://192.168.1.20:8000
```

4. Start Expo.

```bash
npx expo start
```

5. Open Expo Go on your iPhone and scan the QR code from the terminal.

## Notes

- The phone and your Mac must be on the same Wi-Fi network.
- Expo Go can infer your Mac's host IP during development, but `EXPO_PUBLIC_API_BASE_URL` should still be set explicitly for predictable on-device behavior.
- `Scan Room Marker` uses `expo-camera` and calls `POST /v1/rooms/scan`.
- `Open Board` fetches room anchors and can optionally fetch a seed board if `EXPO_PUBLIC_SEED_BOARD_ID` is set.
- AR rendering is intentionally stubbed here. Expo Go is used only for the scan to API to data-display workflow.
