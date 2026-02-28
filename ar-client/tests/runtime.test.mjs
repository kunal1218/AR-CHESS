import assert from 'node:assert/strict';
import test from 'node:test';

import { createStubApi } from '../net/index.js';
import { createGameRuntime, createStockfishStubEvaluator } from '../runtime/index.js';

test('runtime bootstrap loads room, anchors, board, and evaluation', async () => {
  const runtime = createGameRuntime({
    api: createStubApi(),
    evaluator: createStockfishStubEvaluator(),
    boardId: 'demo-board',
  });

  const events = [];
  const unsubscribe = runtime.subscribe((event) => {
    events.push(event.type);
  });

  await runtime.dispatch({ type: 'bootstrap', markerId: 'JOIN-ROOM-001', boardId: 'demo-board' });
  unsubscribe();

  const snapshot = runtime.getSnapshot();
  assert.equal(typeof snapshot.roomId, 'string');
  assert(snapshot.anchorIds.length > 0);
  assert.equal(snapshot.boardId, 'demo-board');
  assert.equal(typeof snapshot.evaluation?.centipawns, 'number');
  assert(events.includes('RoomScanned'));
  assert(events.includes('AnchorsLoaded'));
  assert(events.includes('BoardLoaded'));
  assert(events.includes('EvalReady'));
});

test('runtime move command enforces legality and updates version', async () => {
  const runtime = createGameRuntime({
    api: createStubApi(),
    evaluator: createStockfishStubEvaluator(),
    boardId: 'demo-board',
  });

  await runtime.dispatch({ type: 'bootstrap', markerId: 'JOIN-ROOM-001', boardId: 'demo-board' });

  const before = runtime.getSnapshot();
  const illegal = await runtime.dispatch({ type: 'move', uci: 'e2e5' });
  assert.equal(illegal.ok, false);

  const legal = await runtime.dispatch({ type: 'move', uci: 'e2e4' });
  assert.equal(legal.ok, true);

  const after = runtime.getSnapshot();
  assert.notEqual(after.fen, before.fen);
  assert.equal(after.version, before.version + 1);
});
