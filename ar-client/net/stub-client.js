import { applyLegalMove } from '../core/index.js';

const STARTING_FEN = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

function hashLabel(input) {
  let hash = 0;
  for (let index = 0; index < input.length; index += 1) {
    hash = (hash * 31 + input.charCodeAt(index)) >>> 0;
  }
  return hash.toString(16).slice(0, 8).padStart(8, '0');
}

function makeDefaultPose(seed) {
  const base = Number.parseInt(seed.slice(0, 4), 16);
  const offset = ((base % 200) - 100) / 1000;

  return {
    pos: { x: offset, y: 0, z: -1.2 },
    rot: { x: 0, y: 0, z: 0, w: 1 },
  };
}

export function createStubApi() {
  /** @type {Map<string, string>} */
  const markerToRoom = new Map();
  /** @type {Map<string, {id:string,cloud_anchor_id:string,pose:{pos:{x:number,y:number,z:number},rot:{x:number,y:number,z:number,w:number}},active:boolean}[]>} */
  const roomAnchors = new Map();
  /** @type {Map<string, {fen:string,version:number}>} */
  const boards = new Map([
    ['demo-board', { fen: STARTING_FEN, version: 1 }],
  ]);

  return {
    async scanRoom(markerId) {
      const normalized = markerId.trim().toUpperCase();
      if (!normalized) {
        throw new Error('markerId is required');
      }

      const existingRoom = markerToRoom.get(normalized);
      if (existingRoom) {
        return { room_id: existingRoom };
      }

      const roomId = `room-${hashLabel(normalized)}`;
      markerToRoom.set(normalized, roomId);

      if (!roomAnchors.has(roomId)) {
        roomAnchors.set(roomId, [
          {
            id: `anchor-${hashLabel(`primary:${roomId}`)}`,
            cloud_anchor_id: `cloud-${hashLabel(`cloud:${roomId}`)}`,
            pose: makeDefaultPose(hashLabel(roomId)),
            active: true,
          },
        ]);
      }

      return { room_id: roomId };
    },

    async getAnchors(roomId) {
      const anchors = roomAnchors.get(roomId) ?? [];
      return { anchors };
    },

    async getBoard(boardId) {
      const board = boards.get(boardId);
      if (!board) {
        throw new Error(`Unknown boardId: ${boardId}`);
      }

      return {
        board_id: boardId,
        fen: board.fen,
        version: board.version,
      };
    },

    async postMove(boardId, uci, expectedVersion) {
      const board = boards.get(boardId);
      if (!board) {
        return {
          fen: STARTING_FEN,
          version: 0,
          legal: false,
          reason: `Unknown boardId: ${boardId}`,
        };
      }

      if (board.version !== expectedVersion) {
        return {
          fen: board.fen,
          version: board.version,
          legal: false,
          reason: `Version mismatch. expected=${expectedVersion}, actual=${board.version}`,
        };
      }

      const result = applyLegalMove(board.fen, uci);
      if (!result.legal) {
        return {
          fen: board.fen,
          version: board.version,
          legal: false,
          reason: result.reason,
        };
      }

      board.fen = result.fen;
      board.version += 1;
      return {
        fen: board.fen,
        version: board.version,
        legal: true,
      };
    },

    seedBoard(boardId, fen = STARTING_FEN, version = 1) {
      boards.set(boardId, { fen, version });
    },

    seedAnchors(roomId, anchors) {
      roomAnchors.set(roomId, anchors);
    },
  };
}
