const FILES = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];

const PIECE_TYPES = new Set(['p', 'n', 'b', 'r', 'q', 'k']);
const PROMOTION_TYPES = new Set(['q', 'r', 'b', 'n']);

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

export function oppositeColor(color) {
  return color === 'w' ? 'b' : 'w';
}

export function squareToIndex(square) {
  assert(typeof square === 'string', 'Square must be a string.');
  assert(/^[a-h][1-8]$/.test(square), `Invalid square: ${square}`);

  const file = square.charCodeAt(0) - 97;
  const rank = Number(square[1]) - 1;
  return rank * 8 + file;
}

export function indexToSquare(index) {
  assert(Number.isInteger(index) && index >= 0 && index < 64, `Invalid index: ${index}`);
  const file = index % 8;
  const rank = Math.floor(index / 8);
  return `${FILES[file]}${rank + 1}`;
}

export function getFile(index) {
  return index % 8;
}

export function getRank(index) {
  return Math.floor(index / 8);
}

export function parseUci(uci) {
  assert(typeof uci === 'string', 'UCI must be a string.');
  const normalized = uci.trim().toLowerCase();
  const match = normalized.match(/^([a-h][1-8])([a-h][1-8])([qrbn])?$/);
  assert(Boolean(match), `Invalid UCI move: ${uci}`);

  return {
    from: squareToIndex(match[1]),
    to: squareToIndex(match[2]),
    promotion: match[3] ?? null,
  };
}

export function formatUci(move) {
  const from = indexToSquare(move.from);
  const to = indexToSquare(move.to);
  const promotion = move.promotion ?? '';
  return `${from}${to}${promotion}`;
}

function parsePiece(symbol) {
  const lower = symbol.toLowerCase();
  assert(PIECE_TYPES.has(lower), `Invalid piece symbol: ${symbol}`);
  return {
    color: symbol === lower ? 'b' : 'w',
    type: lower,
  };
}

function pieceToFenSymbol(piece) {
  const symbol = piece.type;
  return piece.color === 'w' ? symbol.toUpperCase() : symbol;
}

function parseBoard(boardText) {
  const board = Array.from({ length: 64 }, () => null);
  const ranks = boardText.split('/');
  assert(ranks.length === 8, 'FEN board must include 8 ranks.');

  for (let fenRank = 0; fenRank < 8; fenRank += 1) {
    const rankText = ranks[fenRank];
    let file = 0;

    for (const token of rankText) {
      if (/[1-8]/.test(token)) {
        file += Number(token);
      } else {
        assert(file < 8, `Too many files in rank: ${rankText}`);
        const boardRank = 7 - fenRank;
        const index = boardRank * 8 + file;
        board[index] = parsePiece(token);
        file += 1;
      }
    }

    assert(file === 8, `Rank does not contain 8 files: ${rankText}`);
  }

  return board;
}

function serializeBoard(board) {
  const fenRanks = [];

  for (let rank = 7; rank >= 0; rank -= 1) {
    let emptyCount = 0;
    let line = '';

    for (let file = 0; file < 8; file += 1) {
      const index = rank * 8 + file;
      const piece = board[index];

      if (!piece) {
        emptyCount += 1;
        continue;
      }

      if (emptyCount > 0) {
        line += String(emptyCount);
        emptyCount = 0;
      }

      line += pieceToFenSymbol(piece);
    }

    if (emptyCount > 0) {
      line += String(emptyCount);
    }

    fenRanks.push(line);
  }

  return fenRanks.join('/');
}

function normalizeCastlingRights(text) {
  if (text === '-') {
    return '';
  }

  assert(/^[KQkq]+$/.test(text), `Invalid castling rights: ${text}`);
  const ordered = ['K', 'Q', 'k', 'q'].filter((token) => text.includes(token));
  return ordered.join('');
}

export function parseFen(fen) {
  assert(typeof fen === 'string', 'FEN must be a string.');
  const parts = fen.trim().split(/\s+/);
  assert(parts.length === 6, `Invalid FEN segment count: ${fen}`);

  const board = parseBoard(parts[0]);
  const activeColor = parts[1];
  assert(activeColor === 'w' || activeColor === 'b', `Invalid side to move: ${activeColor}`);
  const castling = normalizeCastlingRights(parts[2]);
  const enPassant = parts[3] === '-' ? null : parts[3];
  if (enPassant !== null) {
    assert(/^[a-h][1-8]$/.test(enPassant), `Invalid en passant target: ${enPassant}`);
  }

  const halfmove = Number(parts[4]);
  const fullmove = Number(parts[5]);
  assert(Number.isInteger(halfmove) && halfmove >= 0, `Invalid halfmove clock: ${parts[4]}`);
  assert(Number.isInteger(fullmove) && fullmove >= 1, `Invalid fullmove number: ${parts[5]}`);

  return {
    board,
    activeColor,
    castling,
    enPassant,
    halfmove,
    fullmove,
  };
}

export function serializeFen(state) {
  const boardText = serializeBoard(state.board);
  const castling = state.castling && state.castling.length > 0 ? state.castling : '-';
  const enPassant = state.enPassant ?? '-';
  return `${boardText} ${state.activeColor} ${castling} ${enPassant} ${state.halfmove} ${state.fullmove}`;
}

export function cloneState(state) {
  return {
    board: state.board.map((piece) => (piece ? { ...piece } : null)),
    activeColor: state.activeColor,
    castling: state.castling,
    enPassant: state.enPassant,
    halfmove: state.halfmove,
    fullmove: state.fullmove,
  };
}

export function isPromotionPiece(pieceType) {
  return PROMOTION_TYPES.has(pieceType);
}
