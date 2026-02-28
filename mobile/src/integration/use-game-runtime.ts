import {
  createGameRuntime,
  createStockfishStubEvaluator,
  createStubApi,
  type GameCommand,
  type GameEvent,
  type GameSnapshot,
} from 'ar-client';
import { useEffect, useMemo, useState } from 'react';

const DEFAULT_BOARD_ID = 'demo-board';

function buildMarkerId(mode: 'join' | 'create') {
  return mode === 'create' ? 'CREATE-ROOM-001' : 'JOIN-ROOM-001';
}

export function useGameRuntime(mode: 'join' | 'create') {
  const runtime = useMemo(
    () =>
      createGameRuntime({
        api: createStubApi(),
        evaluator: createStockfishStubEvaluator(),
        boardId: DEFAULT_BOARD_ID,
      }),
    []
  );

  const [snapshot, setSnapshot] = useState<GameSnapshot>(runtime.getSnapshot());
  const [events, setEvents] = useState<GameEvent[]>([]);
  const [isBootstrapping, setIsBootstrapping] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    return runtime.subscribe((event, nextSnapshot) => {
      setSnapshot(nextSnapshot);
      setEvents((previous) => [event, ...previous].slice(0, 12));
    });
  }, [runtime]);

  useEffect(() => {
    let active = true;

    async function start() {
      setIsBootstrapping(true);
      setError(null);
      try {
        await runtime.dispatch({
          type: 'bootstrap',
          markerId: buildMarkerId(mode),
          boardId: DEFAULT_BOARD_ID,
        });
      } catch (runtimeError) {
        if (!active) {
          return;
        }
        setError(runtimeError instanceof Error ? runtimeError.message : 'Failed to initialize runtime.');
      } finally {
        if (active) {
          setIsBootstrapping(false);
        }
      }
    }

    void start();
    return () => {
      active = false;
    };
  }, [mode, runtime]);

  async function dispatch(command: GameCommand) {
    setError(null);
    try {
      return await runtime.dispatch(command);
    } catch (runtimeError) {
      setError(runtimeError instanceof Error ? runtimeError.message : 'Runtime command failed.');
      return {
        ok: false,
        reason: runtimeError instanceof Error ? runtimeError.message : 'Runtime command failed.',
      };
    }
  }

  return {
    snapshot,
    events,
    isBootstrapping,
    error,
    dispatch,
  };
}
