# Architecture

## Current intent

This repository is intentionally split so the backend and the AR client can progress independently while sharing only contract artifacts in `shared/`.

## Core concepts

- Room identity is expected to originate from a physical marker that both players can recognize in the same space.
- Spatial placement is expected to use Cloud Anchors so the board can later be aligned consistently across devices.
- Game state is expected to be persisted in the database so turns, board state, and room membership can be recovered independently of the client session.
- `server-app/` and `ar-client/` are decoupled for now. They will connect later through the contract definitions maintained in `shared/`.

## Module boundaries

- `server-app/` will eventually own API handling, persistence, orchestration, and validation.
- `ar-client/` will eventually own device UX, marker recognition, anchor resolution, and rendering.
- `shared/` exists only for the integration contract and DTO definitions.
