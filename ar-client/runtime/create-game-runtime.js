import { applyLegalMove, generateLegalMoves, isInCheck, parseFenState } from '../core/index.js';
import { createStubApi } from '../net/index.js';
import { createStockfishStubEvaluator } from './evaluation.js';

const STARTING_FEN = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

function cloneSnapshot(snapshot) {
  return {
    ...snapshot,
    anchorIds: [...snapshot.anchorIds],
    legalMovesFromSelection: [...snapshot.legalMovesFromSelection],
    evaluation: snapshot.evaluation ? { ...snapshot.evaluation } : null,
  };
}

function derivePositionFields(snapshot) {
  const state = parseFenState(snapshot.fen);
  return {
    ...snapshot,
    activeColor: state.activeColor,
    inCheck: isInCheck(snapshot.fen, state.activeColor),
  };
}

export function createGameRuntime(options = {}) {
  const api = options.api ?? createStubApi();
  const evaluator = options.evaluator ?? createStockfishStubEvaluator();
  const defaultBoardId = options.boardId ?? 'demo-board';
  const defaultFen = options.initialFen ?? STARTING_FEN;

  /** @type {Set<(event: object, snapshot: object) => void>} */
  const listeners = new Set();
  let eventId = 0;
  let snapshot = derivePositionFields({
    boardId: defaultBoardId,
    roomId: null,
    fen: defaultFen,
    version: 1,
    selectedSquare: null,
    legalMovesFromSelection: [],
    anchorIds: [],
    placementMode: 'resolving',
    evaluation: null,
    activeColor: 'w',
    inCheck: false,
  });

  function notify(type, payload = {}) {
    const event = {
      id: ++eventId,
      type,
      timestamp: new Date().toISOString(),
      payload,
    };

    for (const listener of listeners) {
      listener(event, cloneSnapshot(snapshot));
    }
  }

  function setSnapshot(nextSnapshot, eventType = null, payload = {}) {
    snapshot = derivePositionFields(nextSnapshot);
    if (eventType) {
      notify(eventType, payload);
    }
  }

  async function refreshEvaluation(reason) {
    const evaluation = await evaluator.evaluate(snapshot.fen);
    setSnapshot(
      {
        ...snapshot,
        evaluation,
      },
      'EvalReady',
      { reason, evaluation }
    );
  }

  async function bootstrap({ markerId = 'EXPO-ROOM-001', boardId = defaultBoardId } = {}) {
    const room = await api.scanRoom(markerId);
    setSnapshot(
      {
        ...snapshot,
        roomId: room.room_id,
      },
      'RoomScanned',
      { markerId, roomId: room.room_id }
    );

    const anchors = await api.getAnchors(room.room_id);
    setSnapshot(
      {
        ...snapshot,
        roomId: room.room_id,
        anchorIds: anchors.anchors.filter((anchor) => anchor.active).map((anchor) => anchor.cloud_anchor_id),
        placementMode: anchors.anchors.length > 0 ? 'resolving' : 'manual',
      },
      'AnchorsLoaded',
      { roomId: room.room_id, count: anchors.anchors.length }
    );

    const board = await api.getBoard(boardId);
    setSnapshot(
      {
        ...snapshot,
        boardId: board.board_id,
        fen: board.fen,
        version: board.version,
        selectedSquare: null,
        legalMovesFromSelection: [],
      },
      'BoardLoaded',
      { boardId: board.board_id, version: board.version }
    );

    await refreshEvaluation('bootstrap');
    notify('RuntimeReady', { boardId: snapshot.boardId, roomId: snapshot.roomId });
  }

  async function dispatch(command) {
    switch (command.type) {
      case 'bootstrap':
        await bootstrap({
          markerId: command.markerId,
          boardId: command.boardId,
        });
        return { ok: true };
      case 'selectSquare': {
        const legalMoves = command.square
          ? generateLegalMoves(snapshot.fen, command.square)
          : [];
        setSnapshot(
          {
            ...snapshot,
            selectedSquare: command.square ?? null,
            legalMovesFromSelection: legalMoves,
          },
          'SelectionChanged',
          { square: command.square ?? null, legalMoves }
        );
        return { ok: true, legalMoves };
      }
      case 'move': {
        const proposed = applyLegalMove(snapshot.fen, command.uci);
        if (!proposed.legal) {
          notify('IllegalMove', {
            uci: command.uci,
            reason: proposed.reason ?? 'Move is illegal.',
          });
          return { ok: false, reason: proposed.reason };
        }

        const serverResponse = await api.postMove(snapshot.boardId, proposed.uci, snapshot.version);
        if (!serverResponse.legal) {
          setSnapshot(
            {
              ...snapshot,
              fen: serverResponse.fen,
              version: serverResponse.version,
              selectedSquare: null,
              legalMovesFromSelection: [],
            },
            'MoveRejected',
            { uci: proposed.uci, reason: serverResponse.reason ?? 'Server rejected move.' }
          );
          return { ok: false, reason: serverResponse.reason };
        }

        setSnapshot(
          {
            ...snapshot,
            fen: serverResponse.fen,
            version: serverResponse.version,
            selectedSquare: null,
            legalMovesFromSelection: [],
          },
          'MoveApplied',
          {
            uci: proposed.uci,
            version: serverResponse.version,
          }
        );
        await refreshEvaluation('move');
        return { ok: true };
      }
      case 'syncRemoteMove':
        setSnapshot(
          {
            ...snapshot,
            fen: command.fen,
            version: command.version,
            selectedSquare: null,
            legalMovesFromSelection: [],
          },
          'RemoteSyncApplied',
          { version: command.version }
        );
        await refreshEvaluation('remote-sync');
        return { ok: true };
      case 'setAnchors':
        setSnapshot(
          {
            ...snapshot,
            anchorIds: [...command.cloudAnchorIds],
            placementMode: command.cloudAnchorIds.length > 0 ? 'resolving' : 'manual',
          },
          'AnchorsSet',
          { count: command.cloudAnchorIds.length }
        );
        return { ok: true };
      case 'anchorHosted':
        setSnapshot(
          {
            ...snapshot,
            anchorIds: [command.cloudAnchorId, ...snapshot.anchorIds],
            placementMode: 'anchored',
          },
          'AnchorHosted',
          { cloudAnchorId: command.cloudAnchorId }
        );
        return { ok: true };
      default:
        throw new Error(`Unknown command type: ${command.type}`);
    }
  }

  return {
    getSnapshot() {
      return cloneSnapshot(snapshot);
    },
    subscribe(listener) {
      listeners.add(listener);
      listener(
        {
          id: ++eventId,
          type: 'Snapshot',
          timestamp: new Date().toISOString(),
          payload: {},
        },
        cloneSnapshot(snapshot)
      );
      return () => {
        listeners.delete(listener);
      };
    },
    dispatch,
  };
}
