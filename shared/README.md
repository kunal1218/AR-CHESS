# Shared Integration Boundary

This directory is the only intended shared edit surface between the server and AR client developers.

## What belongs here

- API contract definitions
- DTO and payload shape documentation
- Shared rules notes needed for integration alignment

## What does not belong here

- Backend implementation code
- Android implementation code
- Infrastructure configuration unrelated to the contract

Changes in this directory should be reviewed as contract changes before they are merged.
