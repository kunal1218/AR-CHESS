import assert from 'node:assert/strict';
import test from 'node:test';

import { applyLegalMove, generateLegalMoves, isInCheck, isLegalMove, parseFen, serializeFen } from '../core/index.js';

test('FEN parser/serializer round-trips cleanly', () => {
  const fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
  const state = parseFen(fen);
  const serialized = serializeFen(state);
  assert.equal(serialized, fen);
});

test('illegal move is rejected', () => {
  const fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
  assert.equal(isLegalMove(fen, 'e2e5'), false);
});

test('check detection prevents unrelated moves', () => {
  const fen = '4k3/8/8/8/8/8/4r3/R3K3 w Q - 0 1';
  assert.equal(isInCheck(fen, 'w'), true);
  assert.equal(isLegalMove(fen, 'a1a2'), false);
});

test('castling legal generation and execution', () => {
  const fen = 'r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1';
  const kingMoves = generateLegalMoves(fen, 'e1');
  assert(kingMoves.includes('e1g1'));
  assert(kingMoves.includes('e1c1'));

  const result = applyLegalMove(fen, 'e1g1');
  assert.equal(result.legal, true);
  assert.equal(result.fen, 'r3k2r/8/8/8/8/8/8/R4RK1 b kq - 1 1');
});
