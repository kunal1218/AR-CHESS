# server-app

Backend owned by Person 1.

## Scope

- FastAPI service for health checks, pass-and-play move logging, and queue matchmaking
- Postgres-backed `games`, `game_moves`, `tickets`, and `matches` tables
- UCI move notation for Stockfish-compatible consumers

## Local run

1. Create a virtual environment.
2. Install `requirements.txt`.
3. Run `python3 main.py`.

## Environment

- Copy `.env.example` to `.env` for local development if needed.
- Use `.env.railway.example` as the Railway deployment template.
- Prefer `DATABASE_URL` on Railway private networking.
- `DATABASE_PRIVATE_URL` and `DATABASE_PUBLIC_URL` are also accepted if that is how your service variables are wired.
- The app also supports Railway `PG*` variables and finally falls back to `POSTGRES_*` variables.
- Gemini Live uses backend-only secrets:
  - `GEMINI_API_KEY` (required)
  - `GEMINI_LIVE_MODEL` (optional, default `models/gemini-2.5-flash-native-audio-preview-12-2025`)
  - `GEMINI_LIVE_TEMPERATURE`, `GEMINI_LIVE_TOP_P`, `GEMINI_LIVE_TOP_K`, `GEMINI_LIVE_MAX_OUTPUT_TOKENS` (optional tuning)
  - `GEMINI_LIVE_TURN_TIMEOUT_SECONDS` (optional)
- Piper TTS is local-only and reads:
  - `PIPER_VOICES_CONFIG_PATH` (optional, defaults to `server-app/config/piper_voices.json`)
  - `PIPER_BINARY_PATH` (optional override for the Piper executable path)
  - `PIPER_CACHE_DIR` (optional override for the generated wav cache directory)
  - `PIPER_TTS_TIMEOUT_SECONDS` (optional, default `20`)
- Gemini 3 models are not currently supported on the Live API. If you add a non-Live Gemini path later, keep it on a separate model config instead of pointing `GEMINI_LIVE_MODEL` at Gemini 3.

## Health ping

- `GET /health/ping`
- Returns:
  - `Server ping successful`
  - `Postgres ping successful`

## Match move log

- `POST /v1/games`
  - Creates a new server-backed game log and returns `game_id`
- `POST /v1/games/{game_id}/moves`
  - Request body:
    - `ply`
    - `move_uci`
  - `move_uci` must use UCI notation like `e2e4`, `e1g1`, or `e7e8q`
- `GET /v1/games/{game_id}/moves`
  - Returns the ordered move log for that game

Moves are stored in Postgres table `game_moves`, keyed by `game_id` and `ply`.

## Queue matchmaking

- `POST /v1/matchmaking/enqueue`
  - Request body:
    - `player_id`
  - Creates or refreshes a queue ticket for the device.
- `POST /v1/matchmaking/{ticket_id}/heartbeat`
  - Request body:
    - `player_id`
  - Extends queue TTL and can complete pairing if another player is waiting.
- `GET /v1/matchmaking/{ticket_id}?player_id=...`
  - Returns queue status, optional `match_id`, and optional assigned color.
- `DELETE /v1/matchmaking/{ticket_id}?player_id=...`
  - Cancels a waiting ticket.

## Synced match state

- `GET /v1/matches/{match_id}/state?player_id=...`
  - Returns the authoritative game state, assigned color, current move list, and next turn.
- `POST /v1/matches/{match_id}/moves`
  - Request body:
    - `player_id`
    - `ply`
    - `move_uci`
  - Enforces:
    - player membership
    - player color turn order
    - one move per ply
  - Returns `409` with current server state if the client is stale or another move already owns that ply.
- `GET /v1/matches/{match_id}/moves?after_ply=...&player_id=...`
  - Returns ordered moves after the requested ply, plus `latest_ply` and `next_turn`.

Matchmaking uses Postgres transactions and `FOR UPDATE SKIP LOCKED` so two queue tickets cannot pair with the same opponent concurrently.

## Gemini Live hints

- `GET /v1/gemini/status`
  - Returns Gemini Live connection state:
    - `DISCONNECTED`
    - `CONNECTING`
    - `CONNECTED`
    - `ERROR`
  - Response also includes `lastError` and `since`.
- `POST /v1/gemini/hint`
  - Request body:
    - `fen`
    - `recent_history` optional short PGN/SAN sequence (recommended: last 5-10 half-moves)
    - `best_move` (UCI)
    - `side_to_move` (`white` or `black`)
    - `moving_piece` (`pawn`, `knight`, `bishop`, `rook`, `queen`, `king`) optional
    - `is_capture`
    - `gives_check`
    - `themes` list
  - Uses a shared stateful Gemini Live WebSocket session on the backend.
  - Defaults to `models/gemini-2.5-flash-native-audio-preview-12-2025`, because the older `gemini-2.0-flash-live-001` model is shut down and Gemini 3 does not currently support the Live API.
  - Each turn is sent to Gemini as a structured packet with current FEN, recent move narrative, and the query text.
  - Turns are serialized to avoid interleaving.

## Piper TTS

- `POST /v1/tts/piper/speak`
  - Request body:
    - `speaker_type` (`pawn`, `rook`, `knight`, `bishop`, `queen`, `king`, `narrator`)
    - `text`
  - Returns:
    - `cache_key`
    - `cache_hit`
    - `used_fallback_voice`
    - `resolved_speaker_type`
    - `audio_url`
- `GET /v1/tts/piper/audio/{cache_key}`
  - Returns the cached wav file for playback in the client.
- Voice paths live in `server-app/config/piper_voices.json`.
- Generated wav files are cached under `server-app/.cache/piper/` by default.

## Verify locally

1. Start the server: `python3 main.py`
2. Check Gemini Live status:
   - `curl http://localhost:8080/v1/gemini/status`
3. Send a sample hint turn:
   - `curl -X POST http://localhost:8080/v1/gemini/hint -H 'content-type: application/json' -d '{\"fen\":\"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1\",\"recent_history\":\"13. Re1 b5 14. Bb3 Nf6 15. O-O\",\"best_move\":\"e2e4\",\"side_to_move\":\"white\",\"moving_piece\":\"pawn\",\"is_capture\":false,\"gives_check\":false,\"themes\":[\"fight for the center\"]}'`
