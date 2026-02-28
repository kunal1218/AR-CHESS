# ar-client

Person 2 AR client module for local chess state, anchor placement flow, and server-compatible networking stubs.

## Folder layout

- `core/` chess engine (FEN model, legal move generation, move application)
- `ar/` anchored board renderer and tap input handling
- `net/` API interface stubs matching the server contract shape
- `tests/` unit tests for core rules

## What is implemented

- FEN parser + serializer
- Internal board state model
- Legal move generation for:
  - pawns, knights, bishops, rooks, queens, kings
  - check detection and check-safe filtering
  - castling
  - promotion (queen and other promotion pieces)
  - en passant
- Public engine APIs:
  - `isLegalMove(fen, uci)`
  - `generateLegalMoves(fen, square)`
  - `applyLegalMove(fen, uci)`
- AR board UI component:
  - attempts to resolve multiple `cloud_anchor_id` values
  - places board when an anchor resolves
  - falls back to manual placement and local hosted-anchor submit
  - tap-to-select, tap-to-move, legal move enforcement, FEN updates
- Networking stubs:
  - `scanRoom(markerId)`
  - `getAnchors(roomId)`
  - `getBoard(boardId)`
  - `postMove(boardId, uci, expectedVersion)`

## Run tests

```bash
cd ar-client
npm test
```

## Use in Expo mobile app later

Import the AR board component into your mobile route:

```js
import { ARChessboard } from '../ar-client/ar/index.js';
```

Minimal usage:

```jsx
<ARChessboard
  initialFen="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
  cloudAnchorIds={['cloud-anchor-a', 'cloud-anchor-b']}
  onFenChange={(nextFen, moveUci) => {
    console.log('move', moveUci, 'fen', nextFen);
  }}
/>
```

## Server integration mapping (later)

When Person 1 endpoints are live, replace `net/createStubApi()` with HTTP calls:

- `scanRoom(markerId)` -> `POST /v1/rooms/scan`
- `getAnchors(roomId)` -> `GET /v1/rooms/{room_id}/anchors`
- `getBoard(boardId)` -> `GET /v1/boards/{board_id}`
- `postMove(boardId, uci, expectedVersion)` -> `POST /v1/boards/{board_id}/move`

For hosted anchors, wire `submitHostedAnchor(cloud_anchor_id, pose)` to:

- `POST /v1/rooms/{room_id}/anchors`

No server-app code changes are needed for this module.
