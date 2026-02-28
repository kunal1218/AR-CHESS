import {
  cloneState,
  formatUci,
  getFile,
  getRank,
  indexToSquare,
  oppositeColor,
  parseFen,
  parseUci,
  serializeFen,
  squareToIndex,
} from './fen.js';

const KNIGHT_OFFSETS = [
  [1, 2],
  [2, 1],
  [2, -1],
  [1, -2],
  [-1, -2],
  [-2, -1],
  [-2, 1],
  [-1, 2],
];

const KING_OFFSETS = [
  [1, 1],
  [1, 0],
  [1, -1],
  [0, 1],
  [0, -1],
  [-1, 1],
  [-1, 0],
  [-1, -1],
];

const BISHOP_DIRECTIONS = [
  [1, 1],
  [1, -1],
  [-1, 1],
  [-1, -1],
];

const ROOK_DIRECTIONS = [
  [1, 0],
  [-1, 0],
  [0, 1],
  [0, -1],
];

const PROMOTIONS = ['q', 'r', 'b', 'n'];

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function inBounds(file, rank) {
  return file >= 0 && file < 8 && rank >= 0 && rank < 8;
}

function toIndex(file, rank) {
  return rank * 8 + file;
}

function castlingRightForRookSquare(index) {
  switch (index) {
    case 0:
      return 'Q';
    case 7:
      return 'K';
    case 56:
      return 'q';
    case 63:
      return 'k';
    default:
      return null;
  }
}

function removeCastlingRights(castling, rightsToRemove) {
  return castling
    .split('')
    .filter((token) => !rightsToRemove.includes(token))
    .join('');
}

function findKingIndex(state, color) {
  for (let index = 0; index < 64; index += 1) {
    const piece = state.board[index];
    if (piece && piece.color === color && piece.type === 'k') {
      return index;
    }
  }

  return null;
}

function isSquareAttacked(state, targetIndex, byColor) {
  const targetFile = getFile(targetIndex);
  const targetRank = getRank(targetIndex);

  const pawnSourceRank = byColor === 'w' ? targetRank - 1 : targetRank + 1;
  for (const deltaFile of [-1, 1]) {
    const pawnSourceFile = targetFile + deltaFile;
    if (!inBounds(pawnSourceFile, pawnSourceRank)) {
      continue;
    }

    const sourceIndex = toIndex(pawnSourceFile, pawnSourceRank);
    const sourcePiece = state.board[sourceIndex];
    if (sourcePiece && sourcePiece.color === byColor && sourcePiece.type === 'p') {
      return true;
    }
  }

  for (const [dx, dy] of KNIGHT_OFFSETS) {
    const file = targetFile + dx;
    const rank = targetRank + dy;
    if (!inBounds(file, rank)) {
      continue;
    }

    const piece = state.board[toIndex(file, rank)];
    if (piece && piece.color === byColor && piece.type === 'n') {
      return true;
    }
  }

  for (const [dx, dy] of KING_OFFSETS) {
    const file = targetFile + dx;
    const rank = targetRank + dy;
    if (!inBounds(file, rank)) {
      continue;
    }

    const piece = state.board[toIndex(file, rank)];
    if (piece && piece.color === byColor && piece.type === 'k') {
      return true;
    }
  }

  for (const [dx, dy] of BISHOP_DIRECTIONS) {
    let file = targetFile + dx;
    let rank = targetRank + dy;
    while (inBounds(file, rank)) {
      const piece = state.board[toIndex(file, rank)];
      if (piece) {
        if (piece.color === byColor && (piece.type === 'b' || piece.type === 'q')) {
          return true;
        }
        break;
      }
      file += dx;
      rank += dy;
    }
  }

  for (const [dx, dy] of ROOK_DIRECTIONS) {
    let file = targetFile + dx;
    let rank = targetRank + dy;
    while (inBounds(file, rank)) {
      const piece = state.board[toIndex(file, rank)];
      if (piece) {
        if (piece.color === byColor && (piece.type === 'r' || piece.type === 'q')) {
          return true;
        }
        break;
      }
      file += dx;
      rank += dy;
    }
  }

  return false;
}

function isKingInCheck(state, color) {
  const kingIndex = findKingIndex(state, color);
  if (kingIndex === null) {
    return false;
  }

  return isSquareAttacked(state, kingIndex, oppositeColor(color));
}

function canCastleKingSide(state, color) {
  const isWhite = color === 'w';
  const right = isWhite ? 'K' : 'k';
  if (!state.castling.includes(right)) {
    return false;
  }

  const kingIndex = isWhite ? squareToIndex('e1') : squareToIndex('e8');
  const rookIndex = isWhite ? squareToIndex('h1') : squareToIndex('h8');
  const passSquares = isWhite ? [squareToIndex('f1'), squareToIndex('g1')] : [squareToIndex('f8'), squareToIndex('g8')];
  const kingPassSquares = [kingIndex, ...passSquares];

  const king = state.board[kingIndex];
  const rook = state.board[rookIndex];
  if (!king || king.color !== color || king.type !== 'k') {
    return false;
  }
  if (!rook || rook.color !== color || rook.type !== 'r') {
    return false;
  }

  for (const square of passSquares) {
    if (state.board[square]) {
      return false;
    }
  }

  for (const square of kingPassSquares) {
    if (isSquareAttacked(state, square, oppositeColor(color))) {
      return false;
    }
  }

  return true;
}

function canCastleQueenSide(state, color) {
  const isWhite = color === 'w';
  const right = isWhite ? 'Q' : 'q';
  if (!state.castling.includes(right)) {
    return false;
  }

  const kingIndex = isWhite ? squareToIndex('e1') : squareToIndex('e8');
  const rookIndex = isWhite ? squareToIndex('a1') : squareToIndex('a8');
  const emptySquares = isWhite
    ? [squareToIndex('b1'), squareToIndex('c1'), squareToIndex('d1')]
    : [squareToIndex('b8'), squareToIndex('c8'), squareToIndex('d8')];
  const kingPassSquares = isWhite ? [squareToIndex('e1'), squareToIndex('d1'), squareToIndex('c1')] : [squareToIndex('e8'), squareToIndex('d8'), squareToIndex('c8')];

  const king = state.board[kingIndex];
  const rook = state.board[rookIndex];
  if (!king || king.color !== color || king.type !== 'k') {
    return false;
  }
  if (!rook || rook.color !== color || rook.type !== 'r') {
    return false;
  }

  for (const square of emptySquares) {
    if (state.board[square]) {
      return false;
    }
  }

  for (const square of kingPassSquares) {
    if (isSquareAttacked(state, square, oppositeColor(color))) {
      return false;
    }
  }

  return true;
}

function pushMove(moves, from, to, options = {}) {
  moves.push({
    from,
    to,
    promotion: options.promotion ?? null,
    isEnPassant: options.isEnPassant ?? false,
    isCastling: options.isCastling ?? false,
  });
}

function generatePawnMoves(state, from, piece) {
  const moves = [];
  const file = getFile(from);
  const rank = getRank(from);
  const direction = piece.color === 'w' ? 1 : -1;
  const startRank = piece.color === 'w' ? 1 : 6;
  const promotionRank = piece.color === 'w' ? 7 : 0;

  const oneForwardRank = rank + direction;
  if (inBounds(file, oneForwardRank)) {
    const oneForward = toIndex(file, oneForwardRank);
    if (!state.board[oneForward]) {
      if (oneForwardRank === promotionRank) {
        for (const promotion of PROMOTIONS) {
          pushMove(moves, from, oneForward, { promotion });
        }
      } else {
        pushMove(moves, from, oneForward);
      }

      const twoForwardRank = rank + direction * 2;
      if (rank === startRank && inBounds(file, twoForwardRank)) {
        const twoForward = toIndex(file, twoForwardRank);
        if (!state.board[twoForward]) {
          pushMove(moves, from, twoForward);
        }
      }
    }
  }

  for (const deltaFile of [-1, 1]) {
    const targetFile = file + deltaFile;
    const targetRank = rank + direction;
    if (!inBounds(targetFile, targetRank)) {
      continue;
    }

    const target = toIndex(targetFile, targetRank);
    const occupant = state.board[target];
    if (occupant && occupant.color !== piece.color) {
      if (targetRank === promotionRank) {
        for (const promotion of PROMOTIONS) {
          pushMove(moves, from, target, { promotion });
        }
      } else {
        pushMove(moves, from, target);
      }
      continue;
    }

    if (state.enPassant && target === squareToIndex(state.enPassant)) {
      const capturedPawnSquare = toIndex(targetFile, rank);
      const capturedPawn = state.board[capturedPawnSquare];
      if (capturedPawn && capturedPawn.color !== piece.color && capturedPawn.type === 'p') {
        pushMove(moves, from, target, { isEnPassant: true });
      }
    }
  }

  return moves;
}

function generateKnightMoves(state, from, piece) {
  const moves = [];
  const file = getFile(from);
  const rank = getRank(from);

  for (const [dx, dy] of KNIGHT_OFFSETS) {
    const targetFile = file + dx;
    const targetRank = rank + dy;
    if (!inBounds(targetFile, targetRank)) {
      continue;
    }

    const target = toIndex(targetFile, targetRank);
    const occupant = state.board[target];
    if (!occupant || occupant.color !== piece.color) {
      pushMove(moves, from, target);
    }
  }

  return moves;
}

function generateSlidingMoves(state, from, piece, directions) {
  const moves = [];
  const file = getFile(from);
  const rank = getRank(from);

  for (const [dx, dy] of directions) {
    let targetFile = file + dx;
    let targetRank = rank + dy;

    while (inBounds(targetFile, targetRank)) {
      const target = toIndex(targetFile, targetRank);
      const occupant = state.board[target];

      if (!occupant) {
        pushMove(moves, from, target);
      } else {
        if (occupant.color !== piece.color) {
          pushMove(moves, from, target);
        }
        break;
      }

      targetFile += dx;
      targetRank += dy;
    }
  }

  return moves;
}

function generateKingMoves(state, from, piece) {
  const moves = [];
  const file = getFile(from);
  const rank = getRank(from);

  for (const [dx, dy] of KING_OFFSETS) {
    const targetFile = file + dx;
    const targetRank = rank + dy;
    if (!inBounds(targetFile, targetRank)) {
      continue;
    }

    const target = toIndex(targetFile, targetRank);
    const occupant = state.board[target];
    if (!occupant || occupant.color !== piece.color) {
      pushMove(moves, from, target);
    }
  }

  if (canCastleKingSide(state, piece.color)) {
    const to = piece.color === 'w' ? squareToIndex('g1') : squareToIndex('g8');
    pushMove(moves, from, to, { isCastling: true });
  }
  if (canCastleQueenSide(state, piece.color)) {
    const to = piece.color === 'w' ? squareToIndex('c1') : squareToIndex('c8');
    pushMove(moves, from, to, { isCastling: true });
  }

  return moves;
}

function generatePseudoMovesForPiece(state, from, piece) {
  switch (piece.type) {
    case 'p':
      return generatePawnMoves(state, from, piece);
    case 'n':
      return generateKnightMoves(state, from, piece);
    case 'b':
      return generateSlidingMoves(state, from, piece, BISHOP_DIRECTIONS);
    case 'r':
      return generateSlidingMoves(state, from, piece, ROOK_DIRECTIONS);
    case 'q':
      return generateSlidingMoves(state, from, piece, [...BISHOP_DIRECTIONS, ...ROOK_DIRECTIONS]);
    case 'k':
      return generateKingMoves(state, from, piece);
    default:
      return [];
  }
}

function generatePseudoLegalMoves(state, onlyFrom = null) {
  const moves = [];
  const fromIndices = onlyFrom !== null ? [onlyFrom] : Array.from({ length: 64 }, (_, index) => index);

  for (const from of fromIndices) {
    const piece = state.board[from];
    if (!piece || piece.color !== state.activeColor) {
      continue;
    }
    moves.push(...generatePseudoMovesForPiece(state, from, piece));
  }

  return moves;
}

function applyMoveToState(state, move) {
  const next = cloneState(state);
  const piece = next.board[move.from];
  assert(piece, `No piece on source square: ${move.from}`);
  const targetPiece = next.board[move.to];

  const isCapture = Boolean(targetPiece) || move.isEnPassant;
  next.board[move.from] = null;

  if (move.isCastling) {
    next.board[move.to] = piece;
    if (piece.color === 'w') {
      if (move.to === squareToIndex('g1')) {
        next.board[squareToIndex('f1')] = next.board[squareToIndex('h1')];
        next.board[squareToIndex('h1')] = null;
      } else {
        next.board[squareToIndex('d1')] = next.board[squareToIndex('a1')];
        next.board[squareToIndex('a1')] = null;
      }
    } else if (move.to === squareToIndex('g8')) {
      next.board[squareToIndex('f8')] = next.board[squareToIndex('h8')];
      next.board[squareToIndex('h8')] = null;
    } else {
      next.board[squareToIndex('d8')] = next.board[squareToIndex('a8')];
      next.board[squareToIndex('a8')] = null;
    }
  } else if (move.isEnPassant) {
    const capturedPawn = move.to + (piece.color === 'w' ? -8 : 8);
    next.board[capturedPawn] = null;
    next.board[move.to] = move.promotion ? { color: piece.color, type: move.promotion } : piece;
  } else {
    next.board[move.to] = move.promotion ? { color: piece.color, type: move.promotion } : piece;
  }

  let castling = next.castling;
  if (piece.type === 'k') {
    castling = removeCastlingRights(castling, piece.color === 'w' ? ['K', 'Q'] : ['k', 'q']);
  }
  if (piece.type === 'r') {
    const right = castlingRightForRookSquare(move.from);
    if (right) {
      castling = removeCastlingRights(castling, [right]);
    }
  }
  if (targetPiece && targetPiece.type === 'r') {
    const right = castlingRightForRookSquare(move.to);
    if (right) {
      castling = removeCastlingRights(castling, [right]);
    }
  }

  next.castling = castling;
  next.enPassant = null;
  if (piece.type === 'p' && Math.abs(move.to - move.from) === 16) {
    next.enPassant = indexToSquare((move.to + move.from) / 2);
  }

  next.halfmove = piece.type === 'p' || isCapture ? 0 : state.halfmove + 1;
  next.fullmove = state.activeColor === 'b' ? state.fullmove + 1 : state.fullmove;
  next.activeColor = oppositeColor(state.activeColor);

  return next;
}

function generateLegalMovesFromState(state, onlyFrom = null) {
  const pseudoMoves = generatePseudoLegalMoves(state, onlyFrom);
  const legalMoves = [];

  for (const move of pseudoMoves) {
    const next = applyMoveToState(state, move);
    if (!isKingInCheck(next, state.activeColor)) {
      legalMoves.push(move);
    }
  }

  return legalMoves;
}

function matchesUci(uciMove, legalMove) {
  if (uciMove.from !== legalMove.from || uciMove.to !== legalMove.to) {
    return false;
  }

  if (!legalMove.promotion) {
    return uciMove.promotion === null;
  }

  if (uciMove.promotion === null) {
    return legalMove.promotion === 'q';
  }

  return uciMove.promotion === legalMove.promotion;
}

export function isInCheck(fen, color = null) {
  const state = parseFen(fen);
  const checkColor = color ?? state.activeColor;
  return isKingInCheck(state, checkColor);
}

export function generateLegalMoves(fen, square = null) {
  const state = parseFen(fen);
  const from = square ? squareToIndex(square) : null;
  const legalMoves = generateLegalMovesFromState(state, from);
  return legalMoves.map(formatUci);
}

export function isLegalMove(fen, uci) {
  const state = parseFen(fen);
  const parsedMove = parseUci(uci);
  const legalMoves = generateLegalMovesFromState(state, parsedMove.from);
  return legalMoves.some((move) => matchesUci(parsedMove, move));
}

export function applyLegalMove(fen, uci) {
  const state = parseFen(fen);
  const parsedMove = parseUci(uci);
  const legalMoves = generateLegalMovesFromState(state, parsedMove.from);
  const selectedMove = legalMoves.find((move) => matchesUci(parsedMove, move));

  if (!selectedMove) {
    return {
      legal: false,
      fen,
      reason: 'Illegal move for current board state.',
    };
  }

  const next = applyMoveToState(state, selectedMove);
  return {
    legal: true,
    fen: serializeFen(next),
    uci: formatUci(selectedMove),
  };
}

export function parseFenState(fen) {
  return parseFen(fen);
}
