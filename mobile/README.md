# mobile

Archived React Native client for AR Chess. The active iOS app now runs natively from `../ios/ARChess.xcworkspace`.

## Status

- `mobile/` is no longer the primary iOS runtime.
- Native screens and the AR experience now live in `../ios/`.
- Keep this folder only as historical/reference code unless you explicitly want to revive the React Native shell.

## Historical notes

1. Copy `.env.example` to `.env.local`.
2. Set `EXPO_PUBLIC_API_BASE_URL` to your Railway backend URL.

```bash
EXPO_PUBLIC_API_BASE_URL=https://your-railway-service.up.railway.app
```

3. The old React landing screen used `Ping Server + Postgres`.
4. If both checks succeed, the app shows:
   - `Server ping successful`
   - `Postgres ping successful`
