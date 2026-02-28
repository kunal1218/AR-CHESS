# Architecture

## Current intent

This repository is intentionally split so the backend and the Expo mobile client can progress independently while sharing only contract artifacts in `shared/`.

## Core concepts

- Room identity is expected to originate from a physical marker that both players can recognize in the same space.
- Spatial placement is expected to use Cloud Anchors so the board can later be aligned consistently across devices.
- Game state is expected to be persisted in the database so turns, board state, and room membership can be recovered independently of the client session.
- `server-app/` and `mobile/` are decoupled for now. They connect through the contract definitions maintained in `shared/`.
- The current mobile scope ends at scan, API calls, and data display. Native AR placement is intentionally deferred.

## Module boundaries

- `server-app/` will eventually own API handling, persistence, orchestration, and validation.
- `mobile/` owns Expo Go-compatible UX, QR scanning, session state, and server integration.
- A future native AR client can be reintroduced when Cloud Anchor rendering needs capabilities beyond Expo Go.
- `shared/` exists only for the integration contract and DTO definitions.
