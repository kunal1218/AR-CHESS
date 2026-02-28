# Workflow

## Ownership

- Person 1 works only inside `server-app/`.
- Person 2 works only inside `ar-client/`.
- `shared/` is the only shared edit area.
- No cross-folder edits without discussion and explicit agreement first.

## Contract changes

- Any change to files in `shared/` is a contract change.
- Contract changes require PR approval before merging.
- Both developers should treat `shared/` updates as integration checkpoints.

## Branch naming

- Server work: `feature/server-*`
- AR client work: `feature/ar-*`

## Collaboration rule

If work requires changes outside the owner’s folder, pause and discuss the boundary change before opening the PR.
