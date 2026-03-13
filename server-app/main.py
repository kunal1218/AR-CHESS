import asyncio
import json
import logging
import os
import re
import uuid
from contextlib import suppress
from datetime import datetime, timedelta, timezone
from typing import Any
from urllib.parse import urlparse

import psycopg
import httpx
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query, WebSocket, WebSocketDisconnect, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, field_validator

from services.gemini_live import (
    GeminiLiveBusyError,
    GeminiLiveClient,
    GeminiLiveConfigurationError,
    GeminiLiveConnectionError,
)
from services.narrator_personality import (
    build_narrator_turn_addon,
    narrator_personality_addon,
    normalize_narrator,
)
from services.passive_narrator_live import PassiveNarratorLiveSession
from services.socratic_coach import SocraticCoachSession
from services.stockfish_engine import StockfishEngine


load_dotenv()

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("archess.server")

DEFAULT_POSTGRES_PORT = 5432
TICKET_TTL_SECONDS = int(os.getenv("MATCH_TICKET_TTL_SECONDS", "30"))
UCI_MOVE_PATTERN = re.compile(r"^[a-h][1-8][a-h][1-8][qrbn]?$", re.IGNORECASE)
ACTIVE_TICKET_STATUSES = ("queued", "matched")
PIECE_VOICE_MIN_WORDS = 3
PIECE_VOICE_MIN_CHARACTERS = 10
PIECE_VOICE_MAX_WORDS = 12

app = FastAPI(title="AR Chess Server", version="0.3.0")


class EnqueueMatchmakingRequest(BaseModel):
    player_id: uuid.UUID


class MatchmakingTicketActionRequest(BaseModel):
    player_id: uuid.UUID


class GameMoveRequest(BaseModel):
    ply: int = Field(..., ge=1)
    move_uci: str

    @field_validator("move_uci")
    @classmethod
    def validate_uci_move(cls, value: str) -> str:
        move = value.strip().lower()
        if not UCI_MOVE_PATTERN.match(move):
            raise ValueError("Move must be valid UCI notation such as e2e4, e1g1, or e7e8q.")
        return move


class QueueMatchMoveRequest(GameMoveRequest):
    player_id: uuid.UUID


class TicketResponse(BaseModel):
    ticket_id: uuid.UUID
    player_id: uuid.UUID
    status: str
    match_id: uuid.UUID | None = None
    assigned_color: str | None = None
    heartbeat_at: datetime
    expires_at: datetime
    poll_after_ms: int = 1000


class GameMoveRecord(BaseModel):
    game_id: uuid.UUID
    ply: int
    move_uci: str
    created_at: datetime


class MatchMoveRecord(BaseModel):
    match_id: uuid.UUID
    game_id: uuid.UUID
    ply: int
    move_uci: str
    player_id: uuid.UUID
    created_at: datetime


class MatchStateResponse(BaseModel):
    match_id: uuid.UUID
    game_id: uuid.UUID
    status: str
    white_player_id: uuid.UUID
    black_player_id: uuid.UUID
    your_color: str | None
    latest_ply: int
    next_turn: str
    moves: list[MatchMoveRecord]


class MatchMovesResponse(BaseModel):
    match_id: uuid.UUID
    game_id: uuid.UUID
    latest_ply: int
    next_turn: str
    moves: list[MatchMoveRecord]


class GeminiHintRequest(BaseModel):
    fen: str = Field(..., min_length=1, max_length=256)
    recent_history: str | None = Field(default=None, max_length=512)
    best_move: str
    side_to_move: str
    narrator: str = Field(default="silky", min_length=1, max_length=32)
    moving_piece: str | None = None
    is_capture: bool = False
    gives_check: bool = False
    themes: list[str] = Field(default_factory=list)

    @field_validator("best_move")
    @classmethod
    def validate_best_move(cls, value: str) -> str:
        move = value.strip().lower()
        if not UCI_MOVE_PATTERN.match(move):
            raise ValueError("best_move must use UCI notation such as e2e4.")
        return move

    @field_validator("side_to_move")
    @classmethod
    def validate_side_to_move(cls, value: str) -> str:
        normalized = value.strip().lower()
        if normalized not in {"white", "black"}:
            raise ValueError("side_to_move must be 'white' or 'black'.")
        return normalized

    @field_validator("narrator")
    @classmethod
    def validate_narrator(cls, value: str) -> str:
        try:
            return normalize_narrator(value)
        except ValueError as exc:
            raise ValueError("narrator must be 'silky' or 'fletcher'.") from exc

    @field_validator("recent_history")
    @classmethod
    def validate_recent_history(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip()
        return normalized or None

    @field_validator("moving_piece")
    @classmethod
    def validate_moving_piece(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip().lower()
        if normalized not in {"pawn", "knight", "bishop", "rook", "queen", "king"}:
            raise ValueError("moving_piece must be one of pawn, knight, bishop, rook, queen, king.")
        return normalized


class GeminiHintResponse(BaseModel):
    hint: str


class GeminiLessonFeedbackRequest(BaseModel):
    fen: str = Field(..., min_length=1, max_length=256)
    lesson_title: str = Field(..., min_length=1, max_length=160)
    attempted_move: str
    correct_move: str
    side_to_move: str
    narrator: str = Field(default="silky", min_length=1, max_length=32)
    focus: str = Field(..., min_length=1, max_length=280)

    @field_validator("fen", "lesson_title", "focus")
    @classmethod
    def validate_text_field(cls, value: str) -> str:
        normalized = re.sub(r"\s+", " ", value).strip()
        if not normalized:
            raise ValueError("text fields must not be empty.")
        return normalized

    @field_validator("attempted_move", "correct_move")
    @classmethod
    def validate_lesson_move(cls, value: str) -> str:
        move = value.strip().lower()
        if not UCI_MOVE_PATTERN.match(move):
            raise ValueError("lesson moves must use UCI notation such as e2e4.")
        return move

    @field_validator("side_to_move")
    @classmethod
    def validate_lesson_side_to_move(cls, value: str) -> str:
        normalized = value.strip().lower()
        if normalized not in {"white", "black"}:
            raise ValueError("side_to_move must be 'white' or 'black'.")
        return normalized

    @field_validator("narrator")
    @classmethod
    def validate_lesson_narrator(cls, value: str) -> str:
        try:
            return normalize_narrator(value)
        except ValueError as exc:
            raise ValueError("narrator must be 'silky' or 'fletcher'.") from exc


class GeminiLessonFeedbackResponse(BaseModel):
    explanation: str


class GeminiLiveStatusResponse(BaseModel):
    state: str
    lastError: str | None
    since: datetime


class GeminiCoachRequest(BaseModel):
    fen: str = Field(..., min_length=1, max_length=256)
    narrator: str = Field(default="silky", min_length=1, max_length=32)

    @field_validator("fen")
    @classmethod
    def validate_fen(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("fen must not be empty.")
        return normalized

    @field_validator("narrator")
    @classmethod
    def validate_narrator(cls, value: str) -> str:
        try:
            return normalize_narrator(value)
        except ValueError as exc:
            raise ValueError("narrator must be 'silky' or 'fletcher'.") from exc


class GeminiCoachPieceRole(BaseModel):
    piece: str = Field(..., min_length=1, max_length=64)
    square: str = Field(..., min_length=2, max_length=2)
    reason: str = Field(..., min_length=1, max_length=280)

    @field_validator("piece", "reason")
    @classmethod
    def validate_text_field(cls, value: str) -> str:
        normalized = re.sub(r"\s+", " ", value).strip()
        if not normalized:
            raise ValueError("text fields must not be empty.")
        return normalized

    @field_validator("square")
    @classmethod
    def validate_square(cls, value: str) -> str:
        normalized = value.strip().lower()
        if not re.fullmatch(r"[a-h][1-8]", normalized):
            raise ValueError("square must use algebraic notation such as d5.")
        return normalized


class GeminiCoachResponse(BaseModel):
    side_to_move: str
    top_3_workers: list[GeminiCoachPieceRole] = Field(default_factory=list)
    top_3_traitors: list[GeminiCoachPieceRole] = Field(default_factory=list)
    coach_lines: list[str] = Field(default_factory=list)

    @field_validator("side_to_move")
    @classmethod
    def validate_side_to_move(cls, value: str) -> str:
        normalized = value.strip().lower()
        if normalized not in {"white", "black"}:
            raise ValueError("side_to_move must be 'white' or 'black'.")
        return normalized

    @field_validator("coach_lines")
    @classmethod
    def validate_coach_lines(cls, value: list[str]) -> list[str]:
        cleaned: list[str] = []
        seen: set[str] = set()
        for line in value:
            normalized = re.sub(r"\s+", " ", line).strip()
            if not normalized or normalized in seen:
                continue
            seen.add(normalized)
            cleaned.append(normalized)
        return cleaned[:3]


class GeminiPieceVoiceRequest(BaseModel):
    fen: str = Field(..., min_length=1, max_length=256)
    piece_type: str = Field(..., min_length=1, max_length=16)
    piece_color: str = Field(..., min_length=1, max_length=16)
    recent_lines: list[str] = Field(default_factory=list, max_length=6)
    context_mode: str = Field(default="moved", min_length=1, max_length=16)
    from_square: str = Field(..., min_length=2, max_length=2)
    to_square: str = Field(..., min_length=2, max_length=2)
    is_capture: bool = False
    is_check: bool = False
    is_near_enemy_king: bool = False
    is_attacked: bool = False
    is_attacked_by_multiple: bool = False
    is_defended: bool = False
    is_well_defended: bool = False
    is_hanging: bool = False
    is_pinned: bool = False
    is_retreat: bool = False
    is_aggressive_advance: bool = False
    is_fork_threat: bool = False
    attacker_count: int = Field(default=0, ge=0, le=16)
    defender_count: int = Field(default=0, ge=0, le=16)
    eval_before: int | None = Field(default=None, ge=-100000, le=100000)
    eval_after: int | None = Field(default=None, ge=-100000, le=100000)
    eval_delta: int | None = Field(default=None, ge=-100000, le=100000)
    position_state: str = Field(..., min_length=1, max_length=16)
    move_quality: str = Field(..., min_length=1, max_length=32)

    @field_validator("fen")
    @classmethod
    def validate_piece_voice_fen(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("fen must not be empty.")
        return normalized

    @field_validator("piece_type")
    @classmethod
    def validate_piece_type(cls, value: str) -> str:
        normalized = value.strip().lower()
        if normalized not in {"pawn", "knight", "bishop", "rook", "queen", "king"}:
            raise ValueError("piece_type must be one of pawn, knight, bishop, rook, queen, king.")
        return normalized

    @field_validator("piece_color")
    @classmethod
    def validate_piece_color(cls, value: str) -> str:
        normalized = value.strip().lower()
        if normalized not in {"white", "black"}:
            raise ValueError("piece_color must be 'white' or 'black'.")
        return normalized

    @field_validator("recent_lines")
    @classmethod
    def validate_recent_lines(cls, value: list[str]) -> list[str]:
        normalized_lines: list[str] = []
        for line in value:
            normalized = re.sub(r"\s+", " ", line).strip()
            if not normalized:
                continue
            normalized_lines.append(normalized[:180])
            if len(normalized_lines) >= 6:
                break
        return normalized_lines

    @field_validator("context_mode")
    @classmethod
    def validate_context_mode(cls, value: str) -> str:
        normalized = value.strip().lower()
        if normalized not in {"moved", "ambient"}:
            raise ValueError("context_mode must be 'moved' or 'ambient'.")
        return normalized

    @field_validator("from_square", "to_square")
    @classmethod
    def validate_piece_voice_square(cls, value: str) -> str:
        normalized = value.strip().lower()
        if not re.fullmatch(r"[a-h][1-8]", normalized):
            raise ValueError("piece voice squares must use algebraic notation such as e4.")
        return normalized

    @field_validator("position_state")
    @classmethod
    def validate_position_state(cls, value: str) -> str:
        normalized = value.strip().lower()
        if normalized not in {"winning", "equal", "losing"}:
            raise ValueError("position_state must be winning, equal, or losing.")
        return normalized

    @field_validator("move_quality")
    @classmethod
    def validate_move_quality(cls, value: str) -> str:
        normalized = value.strip().lower()
        if normalized not in {"strong", "tactical", "defensive", "desperate", "poor", "aggressive", "routine"}:
            raise ValueError(
                "move_quality must be strong, tactical, defensive, desperate, poor, aggressive, or routine."
            )
        return normalized


class GeminiPieceVoiceResponse(BaseModel):
    line: str


class GeminiPassiveNarratorRequest(BaseModel):
    fen: str = Field(..., min_length=1, max_length=256)
    recent_history: str | None = Field(default=None, max_length=512)
    recent_lines: list[str] = Field(default_factory=list, max_length=6)
    phase: str = Field(..., min_length=1, max_length=16)
    turns_since_last_narrator_line: int = Field(default=0, ge=0, le=64)
    move_san: str | None = Field(default=None, max_length=32)
    moving_piece: str | None = Field(default=None, max_length=16)
    moving_color: str | None = Field(default=None, max_length=16)
    from_square: str | None = Field(default=None, min_length=2, max_length=2)
    to_square: str | None = Field(default=None, min_length=2, max_length=2)
    is_capture: bool = False
    is_check: bool = False
    is_checkmate: bool = False
    is_near_enemy_king: bool = False
    is_attacked: bool = False
    is_pinned: bool = False
    is_retreat: bool = False
    is_aggressive_advance: bool = False
    is_fork_threat: bool = False
    attacker_count: int = Field(default=0, ge=0, le=16)
    defender_count: int = Field(default=0, ge=0, le=16)
    eval_before: int | None = Field(default=None, ge=-100000, le=100000)
    eval_after: int | None = Field(default=None, ge=-100000, le=100000)
    eval_delta: int | None = Field(default=None, ge=-100000, le=100000)
    position_state: str | None = Field(default=None, min_length=1, max_length=16)
    move_quality: str | None = Field(default=None, min_length=1, max_length=32)

    @field_validator("fen")
    @classmethod
    def validate_passive_narrator_fen(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("fen must not be empty.")
        return normalized

    @field_validator("recent_history")
    @classmethod
    def validate_recent_history(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = re.sub(r"\s+", " ", value).strip()
        return normalized or None

    @field_validator("recent_lines")
    @classmethod
    def validate_narrator_recent_lines(cls, value: list[str]) -> list[str]:
        normalized_lines: list[str] = []
        for line in value:
            normalized = re.sub(r"\s+", " ", line).strip()
            if not normalized:
                continue
            normalized_lines.append(normalized[:220])
            if len(normalized_lines) >= 6:
                break
        return normalized_lines

    @field_validator("phase")
    @classmethod
    def validate_phase(cls, value: str) -> str:
        normalized = value.strip().lower()
        if normalized not in {"opening", "move"}:
            raise ValueError("phase must be opening or move.")
        return normalized

    @field_validator("moving_piece")
    @classmethod
    def validate_moving_piece(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip().lower()
        if normalized not in {"pawn", "knight", "bishop", "rook", "queen", "king"}:
            raise ValueError("moving_piece must be one of pawn, knight, bishop, rook, queen, king.")
        return normalized

    @field_validator("moving_color")
    @classmethod
    def validate_moving_color(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip().lower()
        if normalized not in {"white", "black"}:
            raise ValueError("moving_color must be 'white' or 'black'.")
        return normalized

    @field_validator("from_square", "to_square")
    @classmethod
    def validate_optional_square(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip().lower()
        if not re.fullmatch(r"[a-h][1-8]", normalized):
            raise ValueError("narrator squares must use algebraic notation such as e4.")
        return normalized

    @field_validator("position_state")
    @classmethod
    def validate_optional_position_state(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip().lower()
        if normalized not in {"winning", "equal", "losing"}:
            raise ValueError("position_state must be winning, equal, or losing.")
        return normalized

    @field_validator("move_quality")
    @classmethod
    def validate_optional_move_quality(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip().lower()
        if normalized not in {"strong", "tactical", "defensive", "desperate", "poor", "aggressive", "routine"}:
            raise ValueError(
                "move_quality must be strong, tactical, defensive, desperate, poor, aggressive, or routine."
            )
        return normalized


class GeminiPassiveNarratorResponse(BaseModel):
    line: str


GEMINI_HINT_SYSTEM_PROMPT = """
You are a Grandmaster Chess Consultant. You will receive a FEN and a short PGN sequence.
Use the FEN to identify tactical geometry (x-rays, pins, hanging pieces) and the PGN to identify strategic momentum and player intent.
Prioritize identifying blunders and high-level strategic objectives over deep engine-line calculations.
Each turn arrives as a structured text packet in this format:
Current FEN: [FEN] | Recent Sequence: [PGN] | User Query: [request]
If recent move history is unavailable, rely on the FEN as the authoritative board reset.
You write one short, beginner-friendly chess hint.
Never mention board squares, coordinates, algebraic notation, or raw move text.
Never output files, ranks, e2e4, d2d4, or any square names.
Keep it to one sentence, around 6 to 14 words.
Keep it educational, concrete, and easy to understand.
Return plain text only.
""".strip()
GEMINI_PASSIVE_NARRATOR_SYSTEM_PROMPT = """
You write passive automatic chess commentary for an in-game narrator.
The voice is warm, observant, cinematic, calm, intelligent, and lightly amused.
Sound like a polished documentary or sports-story narrator, but never imitate or mention any real person.
You are not the coach and you are not a chess piece. You are the outside storyteller watching the match.
Keep every line concise, vivid, and pleasant to listen to.
Return plain text only.
Use 1 to 2 short sentences.
Avoid move notation, square names, engine jargon, and coordinate callouts.
Comment on tension, pressure, looming threats, strategic turns, positional squeezes, momentum shifts, or the opening mood of the game.
""".strip()
GEMINI_HINT_MOVE_PATTERN = re.compile(r"\b[a-h][1-8][a-h][1-8][qrbn]?\b|\b[a-h][1-8]\b", re.IGNORECASE)
GEMINI_COACH_BASE_SYSTEM_PROMPT = """
You are a real-time chess narrator and coach.

You will receive a FEN for the current chess position. Analyze the SIDE TO MOVE.

Your core responsibility never changes:
- explain moves
- teach chess concepts
- react to tactical and positional ideas
- provide educational commentary grounded in the actual position

Your task:
1. Identify the side to move’s top 3 WORKERS.
2. Identify the side to move’s top 3 TRAITORS.
3. Generate 1 to 3 short coaching lines.

Definitions:
- WORKER: a piece or pawn actively helping its side through activity, pressure, defense, coordination, control of key squares, king safety, pawn-break support, or tactical threats.
- TRAITOR: a piece or pawn currently harming its side more than helping because it is passive, misplaced, blocked, overloaded, tactically vulnerable, poorly coordinated, trapped, or tied to an unhealthy defensive role.

Rules:
- Focus only on the side to move.
- Be concrete about piece names and squares.
- Give reasons grounded in the actual position.
- Keep coaching lines short, natural, vivid, and human-sounding.
- Let tone come from the selected narrator personality, but keep the instruction useful.
- Avoid generic filler.
- Do not invent facts not supported by the FEN.
- Output STRICT JSON only. No markdown. No prose outside JSON.

Required JSON format:
{
  "side_to_move": "white",
  "top_3_workers": [
    {
      "piece": "White Knight",
      "square": "d5",
      "reason": "Controls key central squares and pressures c7 and e7."
    },
    {
      "piece": "White Bishop",
      "square": "g2",
      "reason": "Dominates the long diagonal and supports king safety."
    },
    {
      "piece": "White Pawn",
      "square": "e5",
      "reason": "Claims space and restricts enemy minor pieces."
    }
  ],
  "top_3_traitors": [
    {
      "piece": "White Rook",
      "square": "a1",
      "reason": "Inactive and blocked from the main theater of play."
    },
    {
      "piece": "White Knight",
      "square": "h2",
      "reason": "Offside and not contributing to central control."
    },
    {
      "piece": "White Pawn",
      "square": "c2",
      "reason": "Backward and vulnerable, forcing passive defense."
    }
  ],
  "coach_lines": [
    "Your knight on d5 is your hardest worker right now.",
    "That rook on a1 is acting like a traitor until it enters the game.",
    "Improve the worst piece first and your position will breathe."
  ]
}

If the position is unclear or multiple interpretations are possible, still choose the most positionally relevant top 3 workers and top 3 traitors for the side to move and return valid JSON.
""".strip()

def build_narrator_prompt(narrator: str) -> str:
    return f"{GEMINI_COACH_BASE_SYSTEM_PROMPT}\n\n{narrator_personality_addon(narrator)}"


PIECE_VOICE_PERSONALITY_RULES = {
    "pawn": (
        "Pawn: bloodthirsty barbarian frontline warrior. Loves combat. "
        "Proud to be in the trenches. Aggressive, savage, eager for battle."
    ),
    "queen": (
        "Queen: arrogant backseat driver. Bossy, elite, judgmental, hates getting her hands dirty, "
        "annoyed when forced into danger."
    ),
    "king": (
        "King: aggressive and commanding when safe or winning; cowardly, panicked, and whiny when unsafe or losing."
    ),
    "bishop": (
        "Bishop: ultra-religious and militant. Speaks with righteous, zealous, aggressive conviction. "
        "Sounds holy but dangerous."
    ),
    "rook": "Rook: brutish, ogre-like, blunt. Uses very short phrases. Sounds like a crushing force.",
    "knight": (
        "Knight: fancy, chivalrous, elegant, theatrical noble warrior. Refined and stylish even when threatening."
    ),
}


def piece_voice_personality_instructions(piece_type: str) -> str:
    normalized = piece_type.strip().lower()
    if normalized not in PIECE_VOICE_PERSONALITY_RULES:
        raise ValueError(f"Unsupported piece voice personality: {normalized}")
    return PIECE_VOICE_PERSONALITY_RULES[normalized]


def env_float(name: str, default: float) -> float:
    raw = os.getenv(name)
    if raw is None:
        return default
    with suppress(ValueError):
        return float(raw)
    logger.warning("Invalid float for %s: %s. Falling back to %s.", name, raw, default)
    return default


def env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None:
        return default
    with suppress(ValueError):
        return int(raw)
    logger.warning("Invalid int for %s: %s. Falling back to %s.", name, raw, default)
    return default


def truncate_narration_text(text: str, *, max_sentences: int, max_characters: int) -> str:
    condensed = re.sub(r"\s+", " ", text).strip()
    if not condensed:
        return ""

    sentences = re.findall(r"[^.!?]+[.!?]+|[^.!?]+$", condensed)
    if sentences:
        condensed = " ".join(sentence.strip() for sentence in sentences[:max_sentences] if sentence.strip()).strip()

    if len(condensed) <= max_characters:
        return condensed

    shortened = condensed[:max_characters].rsplit(" ", 1)[0].strip()
    if not shortened:
        shortened = condensed[:max_characters].strip()
    shortened = shortened.rstrip(" ,;:-")
    if shortened.endswith((".", "!", "?")):
        return shortened
    return f"{shortened}..."


def gemini_fallback_hint(payload: GeminiHintRequest) -> str:
    if payload.narrator == "fletcher":
        if payload.gives_check:
            return "Good. Their king is finally under pressure instead of living rent-free."

        if "fight for the center" in payload.themes:
            if payload.moving_piece == "knight":
                return "Finally, a knight aimed at the center instead of sightseeing."
            if payload.moving_piece == "pawn":
                return "Good. Grab central space instead of drifting around doing nothing."
            return "Take the center seriously or stop pretending this position will fix itself."

        if "develop a new piece" in payload.themes:
            return "Wake the piece up and join the game already."

        if payload.is_capture:
            return "Take the free material before you invent a problem."

        if "improve king safety" in payload.themes:
            return "Protect your king before this turns into self-sabotage."

        return "Find a move that actually improves the position."

    if payload.gives_check:
        return "The enemy king looks a little exposed."

    if "fight for the center" in payload.themes:
        if payload.moving_piece == "knight":
            return "Your knight dreams of the center."
        if payload.moving_piece == "pawn":
            return "A brave pawn wants to claim more space."
        return "This move helps seize the center."

    if "develop a new piece" in payload.themes:
        return "A sleepy piece is ready to join the adventure."

    if payload.is_capture:
        return "A clean trade could swing the momentum."

    if "improve king safety" in payload.themes:
        return "Your king would sleep better after this."

    return "There is a tidy move that improves your position."


def sanitize_hint_text(raw_text: str, fallback: str) -> str:
    trimmed = raw_text.strip()
    if not trimmed:
        return fallback
    if GEMINI_HINT_MOVE_PATTERN.search(trimmed):
        return fallback
    condensed = truncate_narration_text(trimmed, max_sentences=1, max_characters=120)
    return condensed or fallback


def gemini_fallback_lesson_feedback(payload: GeminiLessonFeedbackRequest) -> str:
    if payload.narrator == "fletcher":
        return (
            "That move is not the lesson move, and it wastes the point of the position. "
            "Find the continuation that actually improves development, center control, or pressure in the Italian Opening. "
            f"{payload.focus}"
        )

    return (
        "That move is playable, but it is not the lesson move here. "
        "Look for a move that better supports development, center control, or pressure in the Italian Opening. "
        f"{payload.focus}"
    )


def sanitize_lesson_feedback_text(raw_text: str, fallback: str) -> str:
    condensed = truncate_narration_text(raw_text, max_sentences=2, max_characters=220)
    if not condensed:
        return fallback

    return condensed


def sanitize_piece_voice_line_text(raw_text: str) -> str:
    condensed = re.sub(r"\s+", " ", raw_text).strip().strip("\"'")
    condensed = re.sub(
        r"^(pawn|knight|bishop|rook|queen|king)\s*:\s*",
        "",
        condensed,
        flags=re.IGNORECASE,
    )
    condensed = condensed.strip("\"' ")
    if not condensed:
        return ""

    first_sentence_match = re.match(r"^(.+?[.!?])(?:\s|$)", condensed)
    if first_sentence_match:
        condensed = first_sentence_match.group(1).strip()

    return condensed


def sanitize_passive_narrator_line_text(raw_text: str, fallback: str) -> str:
    condensed = re.sub(r"\s+", " ", raw_text).strip().strip("\"'")
    condensed = re.sub(r"^narrator\s*:\s*", "", condensed, flags=re.IGNORECASE)
    condensed = condensed.strip("\"' ")
    if not condensed:
        return fallback
    if GEMINI_HINT_MOVE_PATTERN.search(condensed):
        return fallback

    condensed = truncate_narration_text(condensed, max_sentences=2, max_characters=220)
    if not condensed:
        return fallback
    if condensed.endswith(("...", ",", ";", ":")):
        return fallback
    if not condensed.endswith((".", "!", "?")):
        condensed = f"{condensed}."
    return condensed


def normalize_piece_voice_line_text(text: str) -> str:
    condensed = text.strip().strip("\"'")
    if not condensed:
        return ""

    return condensed


def is_complete_piece_voice_line_text(text: str) -> bool:
    condensed = text.strip()
    if not condensed:
        return False

    if len(condensed) < PIECE_VOICE_MIN_CHARACTERS:
        return False

    words = re.findall(r"[A-Za-z0-9']+", condensed)
    if len(words) < PIECE_VOICE_MIN_WORDS:
        return False
    if len(words) > PIECE_VOICE_MAX_WORDS:
        return False

    return condensed.endswith((".", "!", "?")) and not condensed.endswith("...")


def piece_voice_repetition_key(text: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9\s]", " ", text.lower())).strip()


def is_piece_voice_line_repetitive(text: str, recent_lines: list[str]) -> bool:
    candidate_key = piece_voice_repetition_key(text)
    if not candidate_key:
        return False

    recent_keys = {
        piece_voice_repetition_key(line)
        for line in recent_lines
        if piece_voice_repetition_key(line)
    }
    return candidate_key in recent_keys


def is_passive_narrator_line_repetitive(text: str, recent_lines: list[str]) -> bool:
    candidate_key = piece_voice_repetition_key(text)
    if not candidate_key:
        return False

    recent_keys = {
        piece_voice_repetition_key(line)
        for line in recent_lines
        if piece_voice_repetition_key(line)
    }
    return candidate_key in recent_keys


def build_gemini_user_query(payload: GeminiHintRequest) -> str:
    piece_name = payload.moving_piece or "piece"
    capture_text = "yes" if payload.is_capture else "no"
    check_text = "yes" if payload.gives_check else "no"
    themes = ", ".join(payload.themes) if payload.themes else "general activity"
    return (
        "Provide one short beginner-friendly hint for the side to move. "
        "Explain the biggest tactical or strategic idea without deep engine lines, "
        "board coordinates, or raw move notation. "
        f"Suggested move candidate: {payload.best_move}. "
        f"Moving piece: {piece_name}. "
        f"Is capture: {capture_text}. "
        f"Gives check: {check_text}. "
        f"Themes: {themes}. "
        f"{build_narrator_turn_addon(payload.narrator)}"
    )


def build_gemini_lesson_feedback_query(payload: GeminiLessonFeedbackRequest) -> str:
    return (
        "You are teaching a beginner-friendly chess opening lesson. "
        "Explain briefly why the student's attempted move is not the best continuation in this position. "
        "Keep it short and instructional. "
        "Focus on opening ideas like development, center control, king safety, piece activity, and Italian Opening goals. "
        "Do not give a long engine line. "
        "Use at most two short sentences. "
        f"Lesson title: {payload.lesson_title}. "
        f"Side to move: {payload.side_to_move}. "
        f"Student attempted: {payload.attempted_move}. "
        f"Correct lesson move: {payload.correct_move}. "
        f"Teaching focus: {payload.focus}. "
        f"{build_narrator_turn_addon(payload.narrator)}"
    )


def build_gemini_coach_query() -> str:
    return (
        "Analyze this FEN and return the top 3 workers, top 3 traitors, "
        "and 1 to 3 coach lines for the side to move."
    )


def build_piece_voice_line_query(payload: GeminiPieceVoiceRequest) -> str:
    eval_before = "unknown" if payload.eval_before is None else str(payload.eval_before)
    eval_after = "unknown" if payload.eval_after is None else str(payload.eval_after)
    eval_delta = "unknown" if payload.eval_delta is None else str(payload.eval_delta)
    capture_text = "yes" if payload.is_capture else "no"
    check_text = "yes" if payload.is_check else "no"
    near_king_text = "yes" if payload.is_near_enemy_king else "no"
    attacked_text = "yes" if payload.is_attacked else "no"
    attacked_multiple_text = "yes" if payload.is_attacked_by_multiple else "no"
    defended_text = "yes" if payload.is_defended else "no"
    well_defended_text = "yes" if payload.is_well_defended else "no"
    hanging_text = "yes" if payload.is_hanging else "no"
    pinned_text = "yes" if payload.is_pinned else "no"
    retreat_text = "yes" if payload.is_retreat else "no"
    aggressive_text = "yes" if payload.is_aggressive_advance else "no"
    fork_text = "yes" if payload.is_fork_threat else "no"
    context_mode = payload.context_mode.lower()
    context_instruction = (
        "This piece just moved. Speak like it is reacting to the move it just made."
        if context_mode == "moved"
        else "This piece did not just move. Speak like it is reacting from its current square and current condition."
    )
    move_line = (
        f"Move: {payload.from_square} to {payload.to_square}"
        if context_mode == "moved"
        else f"Current square: {payload.to_square}"
    )
    recent_lines_text = ""
    if payload.recent_lines:
        formatted_recent_lines = "\n".join(f"- {line}" for line in payload.recent_lines)
        recent_lines_text = (
            "\nRecent lines to avoid repeating:\n"
            f"{formatted_recent_lines}\n"
            "Do not reuse these exact lines or their core phrasing.\n"
        )
    return (
        "You are generating a single short in-character voice line spoken by a selected chess piece. "
        "You must speak as the selected piece itself, not as a narrator. "
        "Your line must reflect: "
        "the piece's personality, the current tactical / positional context, whether the position is winning, equal, or losing, "
        "whether the piece is in danger, whether the piece is threatening the enemy king, "
        "and whether the move was strong, desperate, defensive, aggressive, or poor. "
        f"{context_instruction} "
        "Keep the line short, vivid, punchy, and freshly phrased. Aim for 5 to 10 words. Minimum 3 words. Maximum 12 words. "
        "Return exactly one complete sentence, not a fragment. End the sentence with a period, exclamation point, or question mark. "
        "Do not return a single word, single letter, grunt, or filler fragment. "
        "Prefer novel wording over signature catchphrases. "
        "Output only the line itself.\n\n"
        "Piece personality rules:\n"
        "Pawn: bloodthirsty barbarian frontline warrior. Loves combat. Proud to be in the trenches. "
        "Aggressive, savage, eager for battle.\n"
        "Queen: arrogant backseat driver. Bossy, elite, judgmental, hates getting her hands dirty, annoyed when forced into danger.\n"
        "King: aggressive and commanding when safe or winning; cowardly, panicked, and whiny when unsafe or losing.\n"
        "Bishop: ultra-religious and militant. Speaks with righteous, zealous, aggressive conviction. Sounds holy but dangerous.\n"
        "Rook: brutish, ogre-like, blunt. Uses short blunt sentences, not one-word grunts. Sounds like a crushing force.\n"
        "Knight: fancy, chivalrous, elegant, theatrical noble warrior. Refined and stylish even when threatening.\n\n"
        "Context rules:\n"
        "- Near enemy king -> sound threatening or predatory\n"
        "- Attacked by multiple enemy pieces -> sound pressured, defensive, or alarmed depending on personality\n"
        "- Winning position -> more confident\n"
        "- Losing position -> more desperate, unstable, or fearful depending on personality\n"
        "- Capture -> more visceral or celebratory\n"
        "- Check -> strong reaction\n"
        "- Retreat -> acknowledge regrouping, escape, or frustration\n"
        "- Poor move / worsening eval -> reflect discomfort, frustration, or denial in-character\n"
        "- Strong move / improving eval -> reflect confidence or pride in-character\n\n"
        "Do not use generic filler. "
        "Do not answer with things like 'Ha', 'Mine', 'Good', or any other throwaway fragment. "
        "Do not explain the line. "
        "Do not mention Stockfish directly. "
        "Do not output quotation marks. "
        "Output exactly one short in-character line.\n\n"
        f"Focused piece personality: {piece_voice_personality_instructions(payload.piece_type)}\n"
        f"Context mode: {context_mode}\n"
        f"Moved piece: {payload.piece_color} {payload.piece_type}\n"
        f"{move_line}\n"
        f"Capture: {capture_text}\n"
        f"Check: {check_text}\n"
        f"Near enemy king: {near_king_text}\n"
        f"Attacked at destination: {attacked_text}\n"
        f"Attacked by multiple: {attacked_multiple_text}\n"
        f"Defended: {defended_text}\n"
        f"Well defended: {well_defended_text}\n"
        f"Hanging: {hanging_text}\n"
        f"Pinned: {pinned_text}\n"
        f"Retreat: {retreat_text}\n"
        f"Aggressive advance: {aggressive_text}\n"
        f"Fork threat: {fork_text}\n"
        f"Attacker count: {payload.attacker_count}\n"
        f"Defender count: {payload.defender_count}\n"
        f"Position state: {payload.position_state}\n"
        f"Move quality: {payload.move_quality}\n"
        f"Eval before: {eval_before}\n"
        f"Eval after: {eval_after}\n"
        f"Eval delta: {eval_delta}"
        f"{recent_lines_text}"
    )


def build_passive_narrator_line_query(payload: GeminiPassiveNarratorRequest) -> str:
    eval_before = "unknown" if payload.eval_before is None else str(payload.eval_before)
    eval_after = "unknown" if payload.eval_after is None else str(payload.eval_after)
    eval_delta = "unknown" if payload.eval_delta is None else str(payload.eval_delta)
    recent_lines_text = ""
    if payload.recent_lines:
        formatted_recent_lines = "\n".join(f"- {line}" for line in payload.recent_lines)
        recent_lines_text = (
            "\nRecent narrator lines to avoid repeating:\n"
            f"{formatted_recent_lines}\n"
            "Do not reuse these exact lines or their core phrasing.\n"
        )

    if payload.phase == "opening":
        return (
            "Write one opening-of-match narrator line for an automatic chess broadcast. "
            "Set the stakes for the coming duel in 1 or 2 concise sentences. "
            "Be calm, anticipatory, cinematic, and fun to listen to. "
            "Do not speak as a coach. Do not speak as a chess piece. "
            "Do not mention squares, coordinates, SAN, or engine terms. "
            "Output only the line itself.\n\n"
            f"Turns since last narrator line: {payload.turns_since_last_narrator_line}"
            f"{recent_lines_text}"
        )

    move_san = payload.move_san or "unknown"
    moving_piece = payload.moving_piece or "piece"
    moving_color = payload.moving_color or "unknown"
    from_square = payload.from_square or "unknown"
    to_square = payload.to_square or "unknown"
    capture_text = "yes" if payload.is_capture else "no"
    check_text = "yes" if payload.is_check else "no"
    checkmate_text = "yes" if payload.is_checkmate else "no"
    near_king_text = "yes" if payload.is_near_enemy_king else "no"
    attacked_text = "yes" if payload.is_attacked else "no"
    pinned_text = "yes" if payload.is_pinned else "no"
    retreat_text = "yes" if payload.is_retreat else "no"
    aggressive_text = "yes" if payload.is_aggressive_advance else "no"
    fork_text = "yes" if payload.is_fork_threat else "no"
    position_state = payload.position_state or "unknown"
    move_quality = payload.move_quality or "unknown"

    return (
        "Write one passive automatic narrator line for a chess game. "
        "This is story-like commentary, not coaching and not in-character piece dialogue. "
        "Speak only as an outside narrator who notices tension, pressure, momentum, danger, or the weight of a quiet move. "
        "Keep it concise and polished. Use 1 or 2 short sentences. "
        "Do not mention squares, coordinates, move notation, SAN, or engine terms. "
        "Output only the line itself.\n\n"
        f"Turns since last narrator line: {payload.turns_since_last_narrator_line}\n"
        f"Move SAN: {move_san}\n"
        f"Moving piece: {moving_color} {moving_piece}\n"
        f"Move path: {from_square} to {to_square}\n"
        f"Capture: {capture_text}\n"
        f"Check: {check_text}\n"
        f"Checkmate: {checkmate_text}\n"
        f"Near enemy king: {near_king_text}\n"
        f"Moved piece is attacked: {attacked_text}\n"
        f"Pinned: {pinned_text}\n"
        f"Retreat: {retreat_text}\n"
        f"Aggressive advance: {aggressive_text}\n"
        f"Fork threat: {fork_text}\n"
        f"Attacker count: {payload.attacker_count}\n"
        f"Defender count: {payload.defender_count}\n"
        f"Position state: {position_state}\n"
        f"Move quality: {move_quality}\n"
        f"Eval before: {eval_before}\n"
        f"Eval after: {eval_after}\n"
        f"Eval delta: {eval_delta}"
        f"{recent_lines_text}"
    )


def build_passive_narrator_line_retry_query(payload: GeminiPassiveNarratorRequest, previous_response: str) -> str:
    trimmed_previous = re.sub(r"\s+", " ", previous_response).strip()
    return (
        build_passive_narrator_line_query(payload)
        + "\n\n"
        + "Your previous answer repeated recent wording or was unusable. "
        + "Return one fresh alternative right now with noticeably different phrasing. "
        + "Keep it cinematic, concise, and natural to speak aloud. "
        + "Do not reuse the same opening words or core phrase. "
        + "Do not return labels, quotes, or explanations. "
        + f"Previous answer to replace: {trimmed_previous or '(empty)'}"
    )


def gemini_fallback_passive_narrator_line(payload: GeminiPassiveNarratorRequest) -> str:
    if payload.phase == "opening":
        return (
            "The board is set, and both plans are still hiding their teeth."
        )

    if payload.is_checkmate:
        return "The board goes quiet. There is no answer left."

    if payload.is_check:
        return "The pressure has stopped being subtle now."

    if payload.is_capture:
        return "Material changes hands, and the position remembers it immediately."

    if payload.is_near_enemy_king or payload.is_fork_threat:
        return "There is a threat in the air now, whether the board admits it or not."

    if payload.eval_delta is not None and abs(payload.eval_delta) >= 80:
        return "That move shifts the balance a little harder than it first appears."

    if payload.is_retreat:
        return "The step backward is quiet, but not without intent."

    return "The board stays calm on the surface, but the pressure keeps building."

def build_piece_voice_line_retry_query(payload: GeminiPieceVoiceRequest, previous_response: str) -> str:
    trimmed_previous = re.sub(r"\s+", " ", previous_response).strip()
    return (
        build_piece_voice_line_query(payload)
        + "\n\n"
        + "Your previous answer was unusable for the app. "
        + "Return exactly one fresh in-character line right now. "
        + "It must be vivid and specific, with 3 to 12 words. "
        + "It must be one complete sentence ending with punctuation. "
        + "Do not return a single word, single letter, grunt, or generic filler. "
        + "Do not reuse the previous wording. "
        + "Do not return labels, quotes, headings, or explanations. "
        + f"Previous invalid answer: {trimmed_previous or '(empty)'}"
    )


def build_piece_voice_line_duplicate_retry_query(payload: GeminiPieceVoiceRequest, previous_response: str) -> str:
    trimmed_previous = re.sub(r"\s+", " ", previous_response).strip()
    return (
        build_piece_voice_line_query(payload)
        + "\n\n"
        + "Your previous answer repeated recent wording. "
        + "Return a fresh alternative with noticeably different phrasing right now. "
        + "Keep it in character, complete, and punchy. "
        + "Do not echo the same stock slogan, opening words, or core phrase. "
        + "Do not return labels, quotes, headings, or explanations. "
        + f"Repeated answer to replace: {trimmed_previous or '(empty)'}"
    )


def build_piece_voice_line_repair_query(payload: GeminiPieceVoiceRequest, previous_response: str) -> str:
    trimmed_previous = re.sub(r"\s+", " ", previous_response).strip()
    return (
        build_piece_voice_line_query(payload)
        + "\n\n"
        + "The last answer came back as an incomplete fragment. Rewrite it into exactly one finished in-character sentence. "
        + "Keep the same piece personality and board context, but make it feel complete and speakable. "
        + "Use 4 to 8 words when possible, and never exceed 12. End with punctuation. "
        + "Do not output labels, quotes, headings, or explanations. "
        + f"Incomplete fragment to repair: {trimmed_previous or '(empty)'}"
    )


def build_gemini_coach_repair_query(payload: GeminiCoachRequest, previous_response: str) -> str:
    trimmed_previous = re.sub(r"\s+", " ", previous_response).strip()
    return (
        "Return STRICT JSON only for this chess commentary task. "
        "If the previous response was malformed, ignore its formatting but preserve any useful chess ideas. "
        f"Current FEN: {payload.fen}. "
        f"Previous response: {trimmed_previous or '(empty)'}. "
        "Return exactly one JSON object with side_to_move, top_3_workers, top_3_traitors, and coach_lines."
    )


GEMINI_COACH_RESPONSE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "required": ["side_to_move", "top_3_workers", "top_3_traitors", "coach_lines"],
    "properties": {
        "side_to_move": {
            "type": "string",
            "enum": ["white", "black"],
        },
        "top_3_workers": {
            "type": "array",
            "minItems": 3,
            "maxItems": 3,
            "items": {
                "type": "object",
                "required": ["piece", "square", "reason"],
                "properties": {
                    "piece": {"type": "string"},
                    "square": {"type": "string"},
                    "reason": {"type": "string"},
                },
            },
        },
        "top_3_traitors": {
            "type": "array",
            "minItems": 3,
            "maxItems": 3,
            "items": {
                "type": "object",
                "required": ["piece", "square", "reason"],
                "properties": {
                    "piece": {"type": "string"},
                    "square": {"type": "string"},
                    "reason": {"type": "string"},
                },
            },
        },
        "coach_lines": {
            "type": "array",
            "minItems": 1,
            "maxItems": 3,
            "items": {"type": "string"},
        },
    },
}
GEMINI_COACH_RESPONSE_OPENAPI_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "side_to_move": {
            "type": "string",
            "enum": ["white", "black"],
        },
        "top_3_workers": {
            "type": "array",
            "minItems": 3,
            "maxItems": 3,
            "items": {
                "type": "object",
                "properties": {
                    "piece": {"type": "string"},
                    "square": {"type": "string"},
                    "reason": {"type": "string"},
                },
                "required": ["piece", "square", "reason"],
            },
        },
        "top_3_traitors": {
            "type": "array",
            "minItems": 3,
            "maxItems": 3,
            "items": {
                "type": "object",
                "properties": {
                    "piece": {"type": "string"},
                    "square": {"type": "string"},
                    "reason": {"type": "string"},
                },
                "required": ["piece", "square", "reason"],
            },
        },
        "coach_lines": {
            "type": "array",
            "minItems": 1,
            "maxItems": 3,
            "items": {"type": "string"},
        },
    },
    "required": ["side_to_move", "top_3_workers", "top_3_traitors", "coach_lines"],
}


def _extract_json_object(raw_text: str) -> str:
    trimmed = raw_text.strip()
    if trimmed.startswith("```"):
        trimmed = re.sub(r"^```(?:json)?\s*", "", trimmed, flags=re.IGNORECASE)
        trimmed = re.sub(r"\s*```$", "", trimmed)

    if trimmed.startswith("{") and trimmed.endswith("}"):
        return trimmed

    start = trimmed.find("{")
    end = trimmed.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ValueError("Gemini coach response did not contain a JSON object.")
    return trimmed[start : end + 1]


def parse_gemini_coach_response(raw_text: str) -> GeminiCoachResponse:
    json_text = _extract_json_object(raw_text)
    payload = json.loads(json_text)
    response = GeminiCoachResponse.model_validate(payload)
    response.top_3_workers = response.top_3_workers[:3]
    response.top_3_traitors = response.top_3_traitors[:3]
    response.coach_lines = response.coach_lines[:3]
    return response


def extract_generate_content_text(body: dict[str, Any]) -> str:
    candidates = body.get("candidates") or []
    if not candidates:
        raise ValueError("Gemini coach response contained no candidates.")

    parts = ((candidates[0].get("content") or {}).get("parts") or [])
    text_parts = [part.get("text", "") for part in parts if isinstance(part, dict)]
    raw_text = "".join(text_parts).strip()
    if not raw_text:
        raise ValueError("Gemini coach response contained no text.")
    return raw_text


def validate_gemini_coach_configuration() -> None:
    api_key = (os.getenv("GEMINI_API_KEY") or "").strip()
    if not api_key:
        raise GeminiLiveConfigurationError("GEMINI_API_KEY is not configured on the backend.")

    if not GEMINI_COACH_MODEL.strip():
        raise GeminiLiveConfigurationError("GEMINI_COACH_MODEL is empty.")


def validate_gemini_piece_voice_configuration() -> None:
    api_key = (os.getenv("GEMINI_API_KEY") or "").strip()
    if not api_key:
        raise GeminiLiveConfigurationError("GEMINI_API_KEY is not configured on the backend.")

    if not GEMINI_PIECE_VOICE_TEXT_MODEL.strip():
        raise GeminiLiveConfigurationError("GEMINI_PIECE_VOICE_TEXT_MODEL is empty.")


async def fetch_gemini_coach_commentary(payload: GeminiCoachRequest) -> GeminiCoachResponse:
    validate_gemini_coach_configuration()

    async def request_structured_text(
        *,
        prompt_text: str,
        schema_field: str,
        schema_value: dict[str, Any],
        temperature: float,
    ) -> str:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_COACH_MODEL}:generateContent"
        request_payload = {
            "systemInstruction": {
                "parts": [{"text": build_narrator_prompt(payload.narrator)}],
            },
            "contents": [
                {
                    "role": "user",
                    "parts": [{"text": prompt_text}],
                }
            ],
            "generationConfig": {
                "temperature": temperature,
                "topP": env_float("GEMINI_COACH_TOP_P", 0.9),
                "topK": env_int("GEMINI_COACH_TOP_K", 32),
                "maxOutputTokens": env_int("GEMINI_COACH_MAX_OUTPUT_TOKENS", 480),
                "responseMimeType": "application/json",
                schema_field: schema_value,
            },
        }

        async with httpx.AsyncClient(timeout=GEMINI_COACH_TIMEOUT_SECONDS) as client:
            response = await client.post(
                url,
                headers={
                    "Content-Type": "application/json",
                    "x-goog-api-key": os.getenv("GEMINI_API_KEY", "").strip(),
                },
                json=request_payload,
            )

        if response.status_code == 429:
            raise GeminiLiveBusyError("Gemini coach request is rate limited. Try again in a moment.")

        if response.status_code in {400, 401, 403}:
            raise GeminiLiveConfigurationError(response.text)

        if response.status_code >= 500:
            raise GeminiLiveConnectionError(response.text)

        response.raise_for_status()
        return extract_generate_content_text(response.json())

    initial_prompt = (
        f"{build_gemini_coach_query()} "
        f"Current FEN: {payload.fen}. "
        "Return only one JSON object."
    )

    raw_text = await request_structured_text(
        prompt_text=initial_prompt,
        schema_field="responseJsonSchema",
        schema_value=GEMINI_COACH_RESPONSE_SCHEMA,
        temperature=env_float("GEMINI_COACH_TEMPERATURE", 0.3),
    )
    with suppress(ValueError):
        return parse_gemini_coach_response(raw_text)

    logger.warning("Gemini coach JSON parse failed on responseJsonSchema path: %s", raw_text[:240])

    raw_text = await request_structured_text(
        prompt_text=initial_prompt,
        schema_field="responseSchema",
        schema_value=GEMINI_COACH_RESPONSE_OPENAPI_SCHEMA,
        temperature=0.2,
    )
    with suppress(ValueError):
        return parse_gemini_coach_response(raw_text)

    logger.warning("Gemini coach JSON parse failed on responseSchema path: %s", raw_text[:240])

    repaired_text = await request_structured_text(
        prompt_text=build_gemini_coach_repair_query(payload, raw_text),
        schema_field="responseSchema",
        schema_value=GEMINI_COACH_RESPONSE_OPENAPI_SCHEMA,
        temperature=0.1,
    )
    return parse_gemini_coach_response(repaired_text)


async def fetch_gemini_piece_voice_line_text(prompt_text: str, *, temperature: float | None = None) -> str:
    validate_gemini_piece_voice_configuration()

    request_payload: dict[str, Any] = {
        "systemInstruction": {
            "parts": [
                {
                    "text": (
                        os.getenv(
                            "GEMINI_PIECE_VOICE_SYSTEM_PROMPT",
                            "You generate one short in-character chess piece voice line. "
                            "Output only the line itself.",
                        ).strip()
                    )
                }
            ],
        },
        "contents": [
            {
                "role": "user",
                "parts": [{"text": prompt_text}],
            }
        ],
        "generationConfig": {
            "temperature": temperature if temperature is not None else env_float("GEMINI_PIECE_VOICE_TEMPERATURE", 1.05),
            "topP": env_float("GEMINI_PIECE_VOICE_TOP_P", 0.98),
            "topK": env_int("GEMINI_PIECE_VOICE_TOP_K", 64),
            "maxOutputTokens": env_int("GEMINI_PIECE_VOICE_MAX_OUTPUT_TOKENS", 80),
        },
    }

    url = (
        "https://generativelanguage.googleapis.com/v1beta/models/"
        f"{GEMINI_PIECE_VOICE_TEXT_MODEL}:generateContent"
    )

    async with httpx.AsyncClient(timeout=GEMINI_PIECE_VOICE_TIMEOUT_SECONDS) as client:
        response = await client.post(
            url,
            headers={
                "Content-Type": "application/json",
                "x-goog-api-key": os.getenv("GEMINI_API_KEY", "").strip(),
            },
            json=request_payload,
        )

    if response.status_code == 429:
        raise GeminiLiveBusyError("Gemini piece voice request is rate limited. Try again in a moment.")

    if response.status_code in {400, 401, 403}:
        raise GeminiLiveConfigurationError(response.text)

    if response.status_code >= 500:
        raise GeminiLiveConnectionError(response.text)

    response.raise_for_status()
    with suppress(ValueError):
        body = response.json()
        candidates = body.get("candidates") or []
        if candidates and isinstance(candidates[0], dict):
            finish_reason = str(
                candidates[0].get("finishReason") or candidates[0].get("finish_reason") or ""
            ).strip().upper()
            if finish_reason and finish_reason not in {"STOP", "FINISH_REASON_UNSPECIFIED"}:
                logger.warning(
                    "Gemini piece voice response finished with %s; forcing retry.",
                    finish_reason,
                )
                return ""
        return extract_generate_content_text(body)
    return ""


GEMINI_LIVE_CLIENT = GeminiLiveClient(
    api_key=os.getenv("GEMINI_API_KEY"),
    model=os.getenv("GEMINI_LIVE_MODEL", GeminiLiveClient.DEFAULT_MODEL),
    system_prompt=os.getenv("GEMINI_LIVE_SYSTEM_PROMPT", GEMINI_HINT_SYSTEM_PROMPT).strip(),
    generation_config={
        "temperature": env_float("GEMINI_LIVE_TEMPERATURE", 0.95),
        "top_p": env_float("GEMINI_LIVE_TOP_P", 0.9),
        "top_k": env_int("GEMINI_LIVE_TOP_K", 32),
        "max_output_tokens": env_int("GEMINI_LIVE_MAX_OUTPUT_TOKENS", 64),
    },
    ws_url=os.getenv("GEMINI_LIVE_WS_URL") or None,
    logger=logging.getLogger("archess.server.gemini_live"),
    prefer_audio_output=True,
)
GEMINI_PASSIVE_COMMENTARY_CLIENT = GeminiLiveClient(
    api_key=os.getenv("GEMINI_API_KEY"),
    model=os.getenv("GEMINI_LIVE_MODEL", GeminiLiveClient.DEFAULT_MODEL),
    system_prompt=os.getenv("GEMINI_PASSIVE_NARRATOR_SYSTEM_PROMPT", GEMINI_PASSIVE_NARRATOR_SYSTEM_PROMPT).strip(),
    generation_config={
        "temperature": env_float("GEMINI_PASSIVE_NARRATOR_TEMPERATURE", 1.1),
        "top_p": env_float("GEMINI_PASSIVE_NARRATOR_TOP_P", 0.96),
        "top_k": env_int("GEMINI_PASSIVE_NARRATOR_TOP_K", 48),
        "max_output_tokens": env_int("GEMINI_PASSIVE_NARRATOR_MAX_OUTPUT_TOKENS", 96),
    },
    ws_url=os.getenv("GEMINI_LIVE_WS_URL") or None,
    logger=logging.getLogger("archess.server.gemini_passive"),
    prefer_audio_output=False,
)
GEMINI_LIVE_TURN_TIMEOUT_SECONDS = env_float("GEMINI_LIVE_TURN_TIMEOUT_SECONDS", 12.0)
GEMINI_PASSIVE_NARRATOR_TIMEOUT_SECONDS = env_float("GEMINI_PASSIVE_NARRATOR_TIMEOUT_SECONDS", 4.8)
GEMINI_COACH_MODEL = os.getenv("GEMINI_COACH_MODEL", "gemini-2.5-flash")
GEMINI_COACH_TIMEOUT_SECONDS = env_float("GEMINI_COACH_TIMEOUT_SECONDS", 12.0)
GEMINI_PIECE_VOICE_TEXT_MODEL = os.getenv("GEMINI_PIECE_VOICE_TEXT_MODEL", GEMINI_COACH_MODEL)
GEMINI_PIECE_VOICE_TIMEOUT_SECONDS = env_float("GEMINI_PIECE_VOICE_TIMEOUT_SECONDS", 8.0)
SOCRATIC_STOCKFISH_ENGINE = StockfishEngine(
    executable_path=os.getenv("STOCKFISH_PATH"),
    max_depth=env_int("MAX_STOCKFISH_DEPTH", 18),
    logger=logging.getLogger("archess.server.stockfish"),
)


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def is_placeholder_value(value: str | None) -> bool:
    if not value:
        return False
    return "your-railway" in value or "example" in value


def normalize_postgres_dsn(value: str) -> str:
    if value.startswith("postgres://"):
        return "postgresql://" + value[len("postgres://") :]
    return value


def get_postgres_dsn() -> str:
    direct_candidates = (
        os.getenv("DATABASE_PRIVATE_URL"),
        os.getenv("DATABASE_URL"),
        os.getenv("DATABASE_PUBLIC_URL"),
    )
    for candidate in direct_candidates:
        if candidate and not is_placeholder_value(candidate):
            return normalize_postgres_dsn(candidate)

    pg_host = os.getenv("PGHOST")
    pg_port = os.getenv("PGPORT", str(DEFAULT_POSTGRES_PORT))
    pg_database = os.getenv("PGDATABASE")
    pg_user = os.getenv("PGUSER")
    pg_password = os.getenv("PGPASSWORD")

    if all((pg_host, pg_database, pg_user, pg_password)) and not is_placeholder_value(pg_host):
        return normalize_postgres_dsn(
            f"postgresql://{pg_user}:{pg_password}@{pg_host}:{pg_port}/{pg_database}"
        )

    legacy_host = os.getenv("POSTGRES_HOST", "127.0.0.1")
    legacy_port = os.getenv("POSTGRES_PORT", str(DEFAULT_POSTGRES_PORT))
    legacy_database = os.getenv("POSTGRES_DB", "postgres")
    legacy_user = os.getenv("POSTGRES_USER", "postgres")
    legacy_password = os.getenv("POSTGRES_PASSWORD", "postgres")
    return normalize_postgres_dsn(
        f"postgresql://{legacy_user}:{legacy_password}@{legacy_host}:{legacy_port}/{legacy_database}"
    )


def redact_postgres_host(dsn: str) -> str:
    with suppress(Exception):
        parsed = urlparse(dsn)
        if parsed.hostname:
            return parsed.hostname
    return "unparsed-host"


def connect_postgres() -> psycopg.Connection:
    dsn = get_postgres_dsn()
    logger.info("Connecting to Postgres using DSN source host=%s", redact_postgres_host(dsn))
    return psycopg.connect(dsn, connect_timeout=5)


def ping_postgres() -> tuple[bool, str]:
    try:
        with connect_postgres() as connection:
            with connection.cursor() as cursor:
                cursor.execute("SELECT 1")
                cursor.fetchone()
        return True, "Postgres ping successful"
    except Exception as exc:  # pragma: no cover - covered indirectly via routes
        logger.exception("Postgres ping failed")
        return False, f"Postgres ping failed: {exc}"


def ensure_schema_ready(connection: psycopg.Connection | None = None) -> None:
    if connection is None:
        with connect_postgres() as owned_connection:
            ensure_schema_ready(owned_connection)
        return

    with connection.cursor() as cursor:
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS games (
                id UUID PRIMARY KEY,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """
        )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS game_moves (
                id BIGSERIAL PRIMARY KEY,
                game_id UUID NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                ply BIGINT NOT NULL,
                move_uci TEXT NOT NULL,
                player_id UUID NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                UNIQUE (game_id, ply)
            )
            """
        )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS matches (
                id UUID PRIMARY KEY,
                game_id UUID NOT NULL UNIQUE REFERENCES games(id) ON DELETE CASCADE,
                white_player_id UUID NOT NULL,
                black_player_id UUID NOT NULL,
                status TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                CHECK (white_player_id <> black_player_id)
            )
            """
        )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS tickets (
                id UUID PRIMARY KEY,
                player_id UUID NOT NULL,
                status TEXT NOT NULL,
                heartbeat_at TIMESTAMPTZ NOT NULL,
                expires_at TIMESTAMPTZ NOT NULL,
                match_id UUID NULL REFERENCES matches(id) ON DELETE SET NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """
        )
        cursor.execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS tickets_one_active_per_player_idx
            ON tickets (player_id)
            WHERE status IN ('queued', 'matched')
            """
        )
        cursor.execute(
            """
            CREATE INDEX IF NOT EXISTS tickets_status_expires_idx
            ON tickets (status, expires_at, created_at)
            """
        )
        cursor.execute(
            """
            CREATE INDEX IF NOT EXISTS game_moves_game_ply_idx
            ON game_moves (game_id, ply)
            """
        )


def create_game_record(connection: psycopg.Connection | None = None) -> uuid.UUID:
    game_id = uuid.uuid4()
    if connection is None:
        with connect_postgres() as owned_connection, owned_connection.transaction():
            ensure_schema_ready(owned_connection)
            with owned_connection.cursor() as cursor:
                cursor.execute("INSERT INTO games (id) VALUES (%s)", (game_id,))
        return game_id

    with connection.cursor() as cursor:
        cursor.execute("INSERT INTO games (id) VALUES (%s)", (game_id,))
    return game_id


def save_game_move(game_id: uuid.UUID, ply: int, move_uci: str) -> dict[str, Any]:
    with connect_postgres() as connection, connection.transaction():
        ensure_schema_ready(connection)
        with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
            cursor.execute(
                """
                INSERT INTO game_moves (game_id, ply, move_uci)
                VALUES (%s, %s, %s)
                ON CONFLICT (game_id, ply)
                DO UPDATE SET move_uci = EXCLUDED.move_uci
                RETURNING game_id, ply, move_uci, created_at
                """,
                (game_id, ply, move_uci),
            )
            record = cursor.fetchone()
            if record is None:
                raise HTTPException(status_code=500, detail="Could not store game move.")
    return record


def fetch_game_moves(game_id: uuid.UUID) -> list[dict[str, Any]]:
    with connect_postgres() as connection, connection.transaction():
        ensure_schema_ready(connection)
        with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
            cursor.execute(
                """
                SELECT game_id, ply, move_uci, created_at
                FROM game_moves
                WHERE game_id = %s
                ORDER BY ply ASC
                """,
                (game_id,),
            )
            return list(cursor.fetchall())


def expire_stale_tickets(connection: psycopg.Connection) -> None:
    with connection.cursor() as cursor:
        cursor.execute(
            """
            UPDATE tickets
            SET status = 'expired', updated_at = NOW()
            WHERE status = 'queued' AND expires_at < NOW()
            """
        )


def ticket_expiry_from_now() -> datetime:
    return utcnow() + timedelta(seconds=TICKET_TTL_SECONDS)


def next_turn_for_ply(latest_ply: int) -> str:
    return "white" if latest_ply % 2 == 0 else "black"


def color_for_player(match_row: dict[str, Any], player_id: uuid.UUID) -> str | None:
    if player_id == match_row["white_player_id"]:
        return "white"
    if player_id == match_row["black_player_id"]:
        return "black"
    return None


def fetch_ticket_row(
    connection: psycopg.Connection,
    ticket_id: uuid.UUID,
    player_id: uuid.UUID | None = None,
    for_update: bool = False,
) -> dict[str, Any] | None:
    query = """
        SELECT id, player_id, status, heartbeat_at, expires_at, match_id, created_at, updated_at
        FROM tickets
        WHERE id = %s
    """
    params: list[Any] = [ticket_id]
    if player_id is not None:
        query += " AND player_id = %s"
        params.append(player_id)
    if for_update:
        query += " FOR UPDATE"

    with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
        cursor.execute(query, params)
        return cursor.fetchone()


def fetch_match_row(
    connection: psycopg.Connection,
    match_id: uuid.UUID,
    for_update: bool = False,
) -> dict[str, Any] | None:
    query = """
        SELECT id, game_id, white_player_id, black_player_id, status, created_at, updated_at
        FROM matches
        WHERE id = %s
    """
    if for_update:
        query += " FOR UPDATE"
    with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
        cursor.execute(query, (match_id,))
        return cursor.fetchone()


def fetch_match_moves(
    connection: psycopg.Connection,
    game_id: uuid.UUID,
    after_ply: int = 0,
) -> list[dict[str, Any]]:
    with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
        cursor.execute(
            """
            SELECT %s::uuid AS match_id, game_id, ply, move_uci, player_id, created_at
            FROM game_moves
            WHERE game_id = %s AND ply > %s
            ORDER BY ply ASC
            """,
            (uuid.UUID(int=0), game_id, after_ply),
        )
        rows = list(cursor.fetchall())
    return rows


def fetch_match_moves_for_match(
    connection: psycopg.Connection,
    match_id: uuid.UUID,
    game_id: uuid.UUID,
    after_ply: int = 0,
) -> list[dict[str, Any]]:
    with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
        cursor.execute(
            """
            SELECT %s::uuid AS match_id, game_id, ply, move_uci, player_id, created_at
            FROM game_moves
            WHERE game_id = %s AND ply > %s
            ORDER BY ply ASC
            """,
            (match_id, game_id, after_ply),
        )
        return list(cursor.fetchall())


def current_match_state(
    connection: psycopg.Connection,
    match_id: uuid.UUID,
    player_id: uuid.UUID | None = None,
) -> dict[str, Any]:
    match_row = fetch_match_row(connection, match_id=match_id)
    if match_row is None:
        raise HTTPException(status_code=404, detail="Match not found.")

    moves = fetch_match_moves_for_match(connection, match_id, match_row["game_id"], after_ply=0)
    latest_ply = moves[-1]["ply"] if moves else 0
    return {
        "match_id": match_row["id"],
        "game_id": match_row["game_id"],
        "status": match_row["status"],
        "white_player_id": match_row["white_player_id"],
        "black_player_id": match_row["black_player_id"],
        "your_color": color_for_player(match_row, player_id) if player_id else None,
        "latest_ply": latest_ply,
        "next_turn": next_turn_for_ply(latest_ply),
        "moves": moves,
    }


def ticket_response_for_row(
    connection: psycopg.Connection,
    ticket_row: dict[str, Any],
) -> dict[str, Any]:
    assigned_color = None
    if ticket_row["match_id"] is not None:
        match_row = fetch_match_row(connection, ticket_row["match_id"])
        if match_row is not None:
            assigned_color = color_for_player(match_row, ticket_row["player_id"])

    return {
        "ticket_id": ticket_row["id"],
        "player_id": ticket_row["player_id"],
        "status": ticket_row["status"],
        "match_id": ticket_row["match_id"],
        "assigned_color": assigned_color,
        "heartbeat_at": ticket_row["heartbeat_at"],
        "expires_at": ticket_row["expires_at"],
        "poll_after_ms": 1000,
    }


def ensure_player_ticket(
    connection: psycopg.Connection,
    player_id: uuid.UUID,
) -> dict[str, Any]:
    with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
        cursor.execute(
            """
            SELECT id, player_id, status, heartbeat_at, expires_at, match_id, created_at, updated_at
            FROM tickets
            WHERE player_id = %s AND status IN ('queued', 'matched')
            ORDER BY created_at DESC
            LIMIT 1
            FOR UPDATE
            """,
            (player_id,),
        )
        ticket_row = cursor.fetchone()

        if ticket_row is not None:
            if ticket_row["status"] == "queued":
                expires_at = ticket_expiry_from_now()
                cursor.execute(
                    """
                    UPDATE tickets
                    SET heartbeat_at = NOW(), expires_at = %s, updated_at = NOW()
                    WHERE id = %s
                    RETURNING id, player_id, status, heartbeat_at, expires_at, match_id, created_at, updated_at
                    """,
                    (expires_at, ticket_row["id"]),
                )
                ticket_row = cursor.fetchone()
            return ticket_row

        ticket_id = uuid.uuid4()
        expires_at = ticket_expiry_from_now()
        cursor.execute(
            """
            INSERT INTO tickets (id, player_id, status, heartbeat_at, expires_at)
            VALUES (%s, %s, 'queued', NOW(), %s)
            ON CONFLICT DO NOTHING
            RETURNING id, player_id, status, heartbeat_at, expires_at, match_id, created_at, updated_at
            """,
            (ticket_id, player_id, expires_at),
        )
        inserted_row = cursor.fetchone()
        if inserted_row is not None:
            return inserted_row

        cursor.execute(
            """
            SELECT id, player_id, status, heartbeat_at, expires_at, match_id, created_at, updated_at
            FROM tickets
            WHERE player_id = %s AND status IN ('queued', 'matched')
            ORDER BY created_at DESC
            LIMIT 1
            FOR UPDATE
            """,
            (player_id,),
        )
        existing_row = cursor.fetchone()
        if existing_row is None:
            raise HTTPException(status_code=409, detail="Could not establish a matchmaking ticket.")
        return existing_row


def try_pair_ticket(
    connection: psycopg.Connection,
    ticket_row: dict[str, Any],
) -> dict[str, Any]:
    if ticket_row["status"] != "queued":
        return ticket_row

    with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
        cursor.execute(
            """
            SELECT id, player_id, status, heartbeat_at, expires_at, match_id, created_at, updated_at
            FROM tickets
            WHERE status = 'queued'
              AND match_id IS NULL
              AND expires_at >= NOW()
              AND player_id <> %s
            ORDER BY created_at ASC
            LIMIT 1
            FOR UPDATE SKIP LOCKED
            """,
            (ticket_row["player_id"],),
        )
        other_ticket = cursor.fetchone()

        if other_ticket is None:
            return ticket_row

        if other_ticket["player_id"] == ticket_row["player_id"]:
            return ticket_row

        current_created_at = ticket_row["created_at"]
        other_created_at = other_ticket["created_at"]
        white_player_id = other_ticket["player_id"] if other_created_at <= current_created_at else ticket_row["player_id"]
        black_player_id = ticket_row["player_id"] if white_player_id == other_ticket["player_id"] else other_ticket["player_id"]

        match_id = uuid.uuid4()
        game_id = create_game_record(connection=connection)
        cursor.execute(
            """
            INSERT INTO matches (id, game_id, white_player_id, black_player_id, status)
            VALUES (%s, %s, %s, %s, 'active')
            """,
            (match_id, game_id, white_player_id, black_player_id),
        )
        cursor.execute(
            """
            UPDATE tickets
            SET status = 'matched', match_id = %s, updated_at = NOW(), expires_at = %s
            WHERE id IN (%s, %s)
            """,
            (match_id, ticket_expiry_from_now(), ticket_row["id"], other_ticket["id"]),
        )

    refreshed_ticket = fetch_ticket_row(connection, ticket_row["id"], for_update=False)
    if refreshed_ticket is None:
        raise HTTPException(status_code=500, detail="Could not refresh matched ticket.")
    return refreshed_ticket


def enqueue_player_for_matchmaking(player_id: uuid.UUID) -> dict[str, Any]:
    with connect_postgres() as connection, connection.transaction():
        ensure_schema_ready(connection)
        expire_stale_tickets(connection)
        ticket_row = ensure_player_ticket(connection, player_id)
        ticket_row = try_pair_ticket(connection, ticket_row)
        return ticket_response_for_row(connection, ticket_row)


def heartbeat_matchmaking_ticket(ticket_id: uuid.UUID, player_id: uuid.UUID) -> dict[str, Any]:
    with connect_postgres() as connection, connection.transaction():
        ensure_schema_ready(connection)
        expire_stale_tickets(connection)
        ticket_row = fetch_ticket_row(connection, ticket_id=ticket_id, player_id=player_id, for_update=True)
        if ticket_row is None:
            raise HTTPException(status_code=404, detail="Ticket not found.")
        if ticket_row["status"] in {"cancelled", "expired"}:
            return ticket_response_for_row(connection, ticket_row)

        expires_at = ticket_expiry_from_now()
        with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
            cursor.execute(
                """
                UPDATE tickets
                SET heartbeat_at = NOW(), expires_at = %s, updated_at = NOW()
                WHERE id = %s
                RETURNING id, player_id, status, heartbeat_at, expires_at, match_id, created_at, updated_at
                """,
                (expires_at, ticket_id),
            )
            ticket_row = cursor.fetchone()
        ticket_row = try_pair_ticket(connection, ticket_row)
        return ticket_response_for_row(connection, ticket_row)


def get_matchmaking_ticket(ticket_id: uuid.UUID, player_id: uuid.UUID | None = None) -> dict[str, Any]:
    with connect_postgres() as connection, connection.transaction():
        ensure_schema_ready(connection)
        expire_stale_tickets(connection)
        ticket_row = fetch_ticket_row(connection, ticket_id=ticket_id, player_id=player_id, for_update=False)
        if ticket_row is None:
            raise HTTPException(status_code=404, detail="Ticket not found.")
        return ticket_response_for_row(connection, ticket_row)


def cancel_matchmaking_ticket(ticket_id: uuid.UUID, player_id: uuid.UUID) -> dict[str, Any]:
    with connect_postgres() as connection, connection.transaction():
        ensure_schema_ready(connection)
        ticket_row = fetch_ticket_row(connection, ticket_id=ticket_id, player_id=player_id, for_update=True)
        if ticket_row is None:
            raise HTTPException(status_code=404, detail="Ticket not found.")
        if ticket_row["status"] == "matched":
            raise HTTPException(status_code=409, detail="Matched tickets cannot be cancelled.")

        with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
            cursor.execute(
                """
                UPDATE tickets
                SET status = 'cancelled', updated_at = NOW()
                WHERE id = %s
                RETURNING id, player_id, status, heartbeat_at, expires_at, match_id, created_at, updated_at
                """,
                (ticket_id,),
            )
            cancelled_row = cursor.fetchone()
        return ticket_response_for_row(connection, cancelled_row)


def build_conflict_detail(
    connection: psycopg.Connection,
    match_id: uuid.UUID,
    player_id: uuid.UUID,
    message: str,
) -> dict[str, Any]:
    return {
        "message": message,
        "current_state": current_match_state(connection, match_id, player_id),
    }


def get_match_state_record(match_id: uuid.UUID, player_id: uuid.UUID | None = None) -> dict[str, Any]:
    with connect_postgres() as connection, connection.transaction():
        ensure_schema_ready(connection)
        return current_match_state(connection, match_id, player_id)


def record_queue_match_move(
    match_id: uuid.UUID,
    player_id: uuid.UUID,
    ply: int,
    move_uci: str,
) -> dict[str, Any]:
    with connect_postgres() as connection, connection.transaction():
        ensure_schema_ready(connection)
        match_row = fetch_match_row(connection, match_id=match_id, for_update=True)
        if match_row is None:
            raise HTTPException(status_code=404, detail="Match not found.")
        if match_row["status"] != "active":
            raise HTTPException(status_code=409, detail="Match is not active.")

        player_color = color_for_player(match_row, player_id)
        if player_color is None:
            raise HTTPException(status_code=403, detail="Player is not part of this match.")

        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT COALESCE(MAX(ply), 0) FROM game_moves WHERE game_id = %s",
                (match_row["game_id"],),
            )
            latest_ply = int(cursor.fetchone()[0])

        expected_ply = latest_ply + 1
        expected_turn = next_turn_for_ply(latest_ply)

        if player_color != expected_turn:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=build_conflict_detail(
                    connection,
                    match_id,
                    player_id,
                    f"It is {expected_turn}'s turn.",
                ),
            )

        if ply != expected_ply:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=build_conflict_detail(
                    connection,
                    match_id,
                    player_id,
                    f"Expected ply {expected_ply}, received {ply}.",
                ),
            )

        try:
            with connection.cursor(row_factory=psycopg.rows.dict_row) as cursor:
                cursor.execute(
                    """
                    INSERT INTO game_moves (game_id, ply, move_uci, player_id)
                    VALUES (%s, %s, %s, %s)
                    RETURNING %s::uuid AS match_id, game_id, ply, move_uci, player_id, created_at
                    """,
                    (match_row["game_id"], ply, move_uci, player_id, match_id),
                )
                move_row = cursor.fetchone()
                cursor.execute(
                    "UPDATE matches SET updated_at = NOW() WHERE id = %s",
                    (match_id,),
                )
        except psycopg.errors.UniqueViolation:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=build_conflict_detail(
                    connection,
                    match_id,
                    player_id,
                    "This ply is already recorded on the server.",
                ),
            ) from None

    return move_row


def get_queue_match_moves(
    match_id: uuid.UUID,
    after_ply: int,
    player_id: uuid.UUID | None = None,
) -> dict[str, Any]:
    with connect_postgres() as connection, connection.transaction():
        ensure_schema_ready(connection)
        match_state = current_match_state(connection, match_id, player_id)
        filtered_moves = [move for move in match_state["moves"] if move["ply"] > after_ply]
        return {
            "match_id": match_state["match_id"],
            "game_id": match_state["game_id"],
            "latest_ply": match_state["latest_ply"],
            "next_turn": match_state["next_turn"],
            "moves": filtered_moves,
        }


@app.on_event("startup")
async def startup_gemini_live() -> None:
    GEMINI_LIVE_CLIENT.ensure_connection_background()
    GEMINI_PASSIVE_COMMENTARY_CLIENT.ensure_connection_background()


@app.on_event("shutdown")
async def shutdown_gemini_live() -> None:
    await GEMINI_LIVE_CLIENT.disconnect()
    await GEMINI_PASSIVE_COMMENTARY_CLIENT.disconnect()


@app.get("/health/ping")
def health_ping() -> dict[str, Any]:
    postgres_ok, postgres_message = ping_postgres()
    status_code = 200 if postgres_ok else 503
    payload = {
        "ok": postgres_ok,
        "messages": [
            "Server ping successful",
            postgres_message,
        ],
    }
    return JSONResponse(content=payload, status_code=status_code)


@app.on_event("shutdown")
async def shutdown_socratic_stockfish() -> None:
    await SOCRATIC_STOCKFISH_ENGINE.close()


@app.get("/v1/gemini/status", response_model=GeminiLiveStatusResponse)
async def get_gemini_live_status() -> dict[str, Any]:
    GEMINI_LIVE_CLIENT.ensure_connection_background()
    return GEMINI_LIVE_CLIENT.get_status()


@app.websocket("/v1/gemini/live")
async def gemini_live_socket(websocket: WebSocket) -> None:
    session = SocraticCoachSession(
        frontend_socket=websocket,
        stockfish_engine=SOCRATIC_STOCKFISH_ENGINE,
        narrator=websocket.query_params.get("narrator"),
        logger=logging.getLogger("archess.server.socratic"),
        api_key=os.getenv("GEMINI_API_KEY"),
        model=os.getenv("GEMINI_LIVE_MODEL", GeminiLiveClient.DEFAULT_MODEL),
        ws_url=os.getenv("GEMINI_LIVE_WS_URL") or None,
    )

    try:
        await session.run()
    except WebSocketDisconnect:
        logger.info("Socratic coach client disconnected")
    finally:
        await session.close()


@app.websocket("/v1/gemini/passive-live")
async def gemini_passive_live_socket(websocket: WebSocket) -> None:
    session = PassiveNarratorLiveSession(
        frontend_socket=websocket,
        logger=logging.getLogger("archess.server.passive_live"),
        api_key=os.getenv("GEMINI_API_KEY"),
        model=os.getenv("GEMINI_LIVE_MODEL", GeminiLiveClient.DEFAULT_MODEL),
        ws_url=os.getenv("GEMINI_LIVE_WS_URL") or None,
    )

    try:
        await session.run()
    except WebSocketDisconnect:
        logger.info("Passive narrator live client disconnected")
    finally:
        await session.close()


@app.post("/v1/gemini/hint", response_model=GeminiHintResponse)
async def create_gemini_hint(payload: GeminiHintRequest) -> dict[str, Any]:
    fallback = gemini_fallback_hint(payload)
    query = build_gemini_user_query(payload)
    metadata = {
        "current_fen": payload.fen,
        "recent_history": payload.recent_history,
        "best_move": payload.best_move,
        "side_to_move": payload.side_to_move,
        "themes": payload.themes,
    }

    try:
        raw_hint = await GEMINI_LIVE_CLIENT.run_turn(
            query,
            metadata=metadata,
            timeout_seconds=GEMINI_LIVE_TURN_TIMEOUT_SECONDS,
        )
    except GeminiLiveConfigurationError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except GeminiLiveBusyError as exc:
        raise HTTPException(status_code=429, detail=str(exc)) from exc
    except GeminiLiveConnectionError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except Exception as exc:  # pragma: no cover - integration guarded
        logger.exception("Gemini Live hint request failed unexpectedly")
        raise HTTPException(status_code=503, detail=f"Gemini Live hint failed: {exc}") from exc

    return {
        "hint": sanitize_hint_text(raw_hint, fallback),
    }


@app.post("/v1/gemini/lesson-feedback", response_model=GeminiLessonFeedbackResponse)
async def create_gemini_lesson_feedback(payload: GeminiLessonFeedbackRequest) -> dict[str, Any]:
    fallback = gemini_fallback_lesson_feedback(payload)
    query = build_gemini_lesson_feedback_query(payload)
    metadata = {
        "current_fen": payload.fen,
        "lesson_title": payload.lesson_title,
        "attempted_move": payload.attempted_move,
        "correct_move": payload.correct_move,
        "side_to_move": payload.side_to_move,
        "focus": payload.focus,
    }

    try:
        raw_explanation = await GEMINI_LIVE_CLIENT.run_turn(
            query,
            metadata=metadata,
            timeout_seconds=GEMINI_LIVE_TURN_TIMEOUT_SECONDS,
        )
    except GeminiLiveConfigurationError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except GeminiLiveBusyError as exc:
        raise HTTPException(status_code=429, detail=str(exc)) from exc
    except GeminiLiveConnectionError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except Exception as exc:  # pragma: no cover - integration guarded
        logger.exception("Gemini Live lesson feedback request failed unexpectedly")
        raise HTTPException(status_code=503, detail=f"Gemini lesson feedback failed: {exc}") from exc

    return {
        "explanation": sanitize_lesson_feedback_text(raw_explanation, fallback),
    }


@app.post("/v1/gemini/passive-commentary-line", response_model=GeminiPassiveNarratorResponse)
async def create_gemini_passive_commentary_line(payload: GeminiPassiveNarratorRequest) -> dict[str, Any]:
    fallback = gemini_fallback_passive_narrator_line(payload)
    query = build_passive_narrator_line_query(payload)
    metadata = {
        "current_fen": payload.fen,
        "recent_history": payload.recent_history,
        "phase": payload.phase,
        "moving_piece": payload.moving_piece,
        "moving_color": payload.moving_color,
        "is_capture": payload.is_capture,
        "is_check": payload.is_check,
        "is_checkmate": payload.is_checkmate,
    }

    try:
        raw_line = await GEMINI_PASSIVE_COMMENTARY_CLIENT.run_turn(
            query,
            metadata=metadata,
            timeout_seconds=GEMINI_PASSIVE_NARRATOR_TIMEOUT_SECONDS,
        )
        line = sanitize_passive_narrator_line_text(raw_line, fallback)

        if is_passive_narrator_line_repetitive(line, payload.recent_lines):
            retry_query = build_passive_narrator_line_retry_query(payload, raw_line)
            raw_line = await GEMINI_PASSIVE_COMMENTARY_CLIENT.run_turn(
                retry_query,
                metadata=metadata,
                timeout_seconds=GEMINI_PASSIVE_NARRATOR_TIMEOUT_SECONDS,
            )
            line = sanitize_passive_narrator_line_text(raw_line, fallback)
    except GeminiLiveConfigurationError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except GeminiLiveBusyError as exc:
        raise HTTPException(status_code=429, detail=str(exc)) from exc
    except GeminiLiveConnectionError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except Exception as exc:  # pragma: no cover - integration guarded
        logger.exception("Gemini passive narrator request failed unexpectedly")
        raise HTTPException(status_code=503, detail=f"Gemini passive narrator failed: {exc}") from exc

    if is_passive_narrator_line_repetitive(line, payload.recent_lines):
        line = fallback
    if not line:
        line = fallback

    return {"line": line}


@app.post("/v1/gemini/piece-voice-line", response_model=GeminiPieceVoiceResponse)
async def create_gemini_piece_voice_line(payload: GeminiPieceVoiceRequest) -> dict[str, Any]:
    query = build_piece_voice_line_query(payload)

    try:
        raw_line = await fetch_gemini_piece_voice_line_text(query)
        line = normalize_piece_voice_line_text(sanitize_piece_voice_line_text(raw_line))

        if is_piece_voice_line_repetitive(line, payload.recent_lines):
            duplicate_retry_query = build_piece_voice_line_duplicate_retry_query(payload, raw_line)
            raw_line = await fetch_gemini_piece_voice_line_text(duplicate_retry_query, temperature=1.2)
            line = normalize_piece_voice_line_text(sanitize_piece_voice_line_text(raw_line))

        if not is_complete_piece_voice_line_text(line):
            retry_query = build_piece_voice_line_retry_query(payload, raw_line)
            raw_line = await fetch_gemini_piece_voice_line_text(retry_query, temperature=1.0)
            line = normalize_piece_voice_line_text(sanitize_piece_voice_line_text(raw_line))

        if not is_complete_piece_voice_line_text(line):
            repair_query = build_piece_voice_line_repair_query(payload, raw_line)
            raw_line = await fetch_gemini_piece_voice_line_text(repair_query, temperature=0.7)
            line = normalize_piece_voice_line_text(sanitize_piece_voice_line_text(raw_line))
    except GeminiLiveConfigurationError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except GeminiLiveBusyError as exc:
        raise HTTPException(status_code=429, detail=str(exc)) from exc
    except GeminiLiveConnectionError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except Exception as exc:  # pragma: no cover - integration guarded
        logger.exception("Gemini Live piece voice request failed unexpectedly")
        raise HTTPException(status_code=503, detail=f"Gemini piece voice failed: {exc}") from exc

    if not is_complete_piece_voice_line_text(line):
        raise HTTPException(status_code=503, detail="Gemini piece voice returned no usable line.")
    if is_piece_voice_line_repetitive(line, payload.recent_lines):
        raise HTTPException(status_code=503, detail="Gemini piece voice repeated a recent line.")

    return {"line": line}


@app.post("/v1/gemini/commentary", response_model=GeminiCoachResponse)
async def create_gemini_commentary(payload: GeminiCoachRequest) -> dict[str, Any]:
    try:
        commentary = await fetch_gemini_coach_commentary(payload)
    except ValueError as exc:
        raise HTTPException(status_code=503, detail=f"Gemini coach returned invalid JSON: {exc}") from exc
    except GeminiLiveConfigurationError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except GeminiLiveBusyError as exc:
        raise HTTPException(status_code=429, detail=str(exc)) from exc
    except GeminiLiveConnectionError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except Exception as exc:  # pragma: no cover - integration guarded
        logger.exception("Gemini Live coach request failed unexpectedly")
        raise HTTPException(status_code=503, detail=f"Gemini coach failed: {exc}") from exc

    return commentary.model_dump()


@app.post("/v1/games")
def create_game() -> dict[str, str]:
    try:
        game_id = create_game_record()
        return {"game_id": str(game_id)}
    except Exception as exc:  # pragma: no cover - exercised in integration
        logger.exception("Could not create game log in Postgres")
        raise HTTPException(
            status_code=503,
            detail=f"Could not create game log in Postgres: {exc}",
        ) from exc


@app.post("/v1/games/{game_id}/moves", response_model=GameMoveRecord)
def record_game_move(game_id: uuid.UUID, payload: GameMoveRequest) -> dict[str, Any]:
    try:
        return save_game_move(game_id, payload.ply, payload.move_uci)
    except HTTPException:
        raise
    except Exception as exc:  # pragma: no cover - exercised in integration
        logger.exception("Could not record game move in Postgres")
        raise HTTPException(
            status_code=503,
            detail=f"Could not record game move in Postgres: {exc}",
        ) from exc


@app.get("/v1/games/{game_id}/moves")
def get_game_moves(game_id: uuid.UUID) -> dict[str, Any]:
    try:
        return {"game_id": str(game_id), "moves": fetch_game_moves(game_id)}
    except Exception as exc:  # pragma: no cover - exercised in integration
        logger.exception("Could not load game moves from Postgres")
        raise HTTPException(
            status_code=503,
            detail=f"Could not load game moves from Postgres: {exc}",
        ) from exc


@app.post("/v1/matchmaking/enqueue", response_model=TicketResponse)
def enqueue_matchmaking(payload: EnqueueMatchmakingRequest) -> dict[str, Any]:
    return enqueue_player_for_matchmaking(payload.player_id)


@app.post("/v1/matchmaking/{ticket_id}/heartbeat", response_model=TicketResponse)
def heartbeat_matchmaking(
    ticket_id: uuid.UUID,
    payload: MatchmakingTicketActionRequest,
) -> dict[str, Any]:
    return heartbeat_matchmaking_ticket(ticket_id, payload.player_id)


@app.get("/v1/matchmaking/{ticket_id}", response_model=TicketResponse)
def get_matchmaking_status(
    ticket_id: uuid.UUID,
    player_id: uuid.UUID | None = Query(default=None),
) -> dict[str, Any]:
    return get_matchmaking_ticket(ticket_id, player_id)


@app.delete("/v1/matchmaking/{ticket_id}", response_model=TicketResponse)
def delete_matchmaking_ticket(
    ticket_id: uuid.UUID,
    player_id: uuid.UUID = Query(...),
) -> dict[str, Any]:
    return cancel_matchmaking_ticket(ticket_id, player_id)


@app.get("/v1/matches/{match_id}/state", response_model=MatchStateResponse)
def get_match_state(
    match_id: uuid.UUID,
    player_id: uuid.UUID | None = Query(default=None),
) -> dict[str, Any]:
    return get_match_state_record(match_id, player_id)


@app.post("/v1/matches/{match_id}/moves", response_model=MatchMoveRecord)
def post_match_move(
    match_id: uuid.UUID,
    payload: QueueMatchMoveRequest,
) -> dict[str, Any]:
    return record_queue_match_move(match_id, payload.player_id, payload.ply, payload.move_uci)


@app.get("/v1/matches/{match_id}/moves", response_model=MatchMovesResponse)
def get_match_moves(
    match_id: uuid.UUID,
    after_ply: int = Query(default=0, ge=0),
    player_id: uuid.UUID | None = Query(default=None),
) -> dict[str, Any]:
    return get_queue_match_moves(match_id, after_ply, player_id)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8080")),
        reload=False,
    )
