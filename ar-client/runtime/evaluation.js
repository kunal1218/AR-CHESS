import { parseFenState } from '../core/index.js';

const PIECE_VALUES = {
  p: 100,
  n: 320,
  b: 330,
  r: 500,
  q: 900,
  k: 0,
};

/**
 * Stockfish-compatible shape stub for Expo Go development.
 * Replace `evaluate` with a real engine bridge when native/remote Stockfish is ready.
 */
export function createStockfishStubEvaluator() {
  return {
    name: 'stockfish-stub',
    async evaluate(fen) {
      const state = parseFenState(fen);
      let score = 0;

      for (const piece of state.board) {
        if (!piece) {
          continue;
        }

        const value = PIECE_VALUES[piece.type] ?? 0;
        score += piece.color === 'w' ? value : -value;
      }

      return {
        source: 'stockfish-stub',
        centipawns: state.activeColor === 'w' ? score : -score,
        mateIn: null,
        pv: [],
      };
    },
  };
}

export function createCustomEvaluator(evaluate) {
  return {
    name: 'custom-evaluator',
    evaluate,
  };
}
