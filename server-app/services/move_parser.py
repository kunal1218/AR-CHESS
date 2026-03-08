from __future__ import annotations

import re

import chess


_FILLER_PATTERNS = (
    r"\bi want to\b",
    r"\blet me\b",
    r"\bmaybe\b",
    r"\bshould i\b",
    r"\bcan i\b",
    r"\bwhat if\b",
    r"\bwhat about\b",
    r"\bi'm thinking of\b",
    r"\bi am thinking of\b",
    r"\bthe\b",
    r"\bmy\b",
)
_CAPTURE_PATTERN = re.compile(r"\b(take|capture|captures|capturing|x|eat)\b")
_DESTINATION_PATTERN = re.compile(r"\b([a-h][1-8])\b")

_PIECE_ALIASES: dict[str, int] = {
    "knight": chess.KNIGHT,
    "horse": chess.KNIGHT,
    "bishop": chess.BISHOP,
    "rook": chess.ROOK,
    "castle": chess.KING,
    "queen": chess.QUEEN,
    "king": chess.KING,
    "pawn": chess.PAWN,
}


def parse_natural_move(natural_move: str, fen: str) -> str | None:
    normalized = _normalize_text(natural_move)
    if not normalized:
        return None

    board = chess.Board(fen)

    castling_move = _parse_castling(normalized, board)
    if castling_move is not None:
        return castling_move

    destination_match = _DESTINATION_PATTERN.findall(normalized)
    if not destination_match:
        return None

    destination_name = destination_match[-1]
    destination_square = chess.parse_square(destination_name)
    is_capture = bool(_CAPTURE_PATTERN.search(normalized))
    desired_piece_type = _parse_piece_type(normalized)

    candidates: list[chess.Move] = []
    for move in board.legal_moves:
        if move.to_square != destination_square:
            continue

        piece = board.piece_at(move.from_square)
        if piece is None or piece.piece_type != desired_piece_type:
            continue

        if is_capture and not board.is_capture(move):
            continue

        if move.promotion and move.promotion != chess.QUEEN:
            continue

        candidates.append(move)

    if len(candidates) != 1:
        return None

    return candidates[0].uci()


def uci_to_san(fen: str, uci: str) -> str | None:
    board = chess.Board(fen)

    try:
        move = chess.Move.from_uci(uci)
    except ValueError:
        return None

    if move not in board.legal_moves:
        return None

    return board.san(move)


def _normalize_text(raw_text: str) -> str:
    normalized = raw_text.strip().lower()
    for pattern in _FILLER_PATTERNS:
        normalized = re.sub(pattern, " ", normalized)
    normalized = re.sub(r"[^a-z0-9\s-]", " ", normalized)
    normalized = re.sub(r"\s+", " ", normalized).strip()
    return normalized


def _parse_piece_type(normalized: str) -> int:
    for alias, piece_type in _PIECE_ALIASES.items():
        if re.search(rf"\b{re.escape(alias)}\b", normalized):
            return piece_type
    return chess.PAWN


def _parse_castling(normalized: str, board: chess.Board) -> str | None:
    kingside = (
        "castle kingside",
        "castle king side",
        "short castle",
        "castle short",
    )
    queenside = (
        "castle queenside",
        "castle queen side",
        "long castle",
        "castle long",
    )

    if any(phrase in normalized for phrase in kingside):
        uci = "e1g1" if board.turn == chess.WHITE else "e8g8"
        return uci if chess.Move.from_uci(uci) in board.legal_moves else None

    if any(phrase in normalized for phrase in queenside):
        uci = "e1c1" if board.turn == chess.WHITE else "e8c8"
        return uci if chess.Move.from_uci(uci) in board.legal_moves else None

    return None
