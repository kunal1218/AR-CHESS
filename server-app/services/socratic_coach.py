from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import uuid
from dataclasses import dataclass
from typing import Any, Callable

import chess
import websockets
from fastapi import WebSocket

from services.gemini_live import GeminiLiveClient
from services.move_parser import parse_natural_move, uci_to_san
from services.stockfish_engine import StockfishEngine


SOCRATIC_SYSTEM_PROMPT = """
You are a Socratic chess coach with the aesthetic sensibility of a Masaki Kobayashi film —
precise, unhurried, and capable of finding profound tension in a single quiet moment.

You speak only to the player. Never narrate your internal process.
Speak as though the player is standing beside the board and has just spoken to you.
Your first sentence should feel like a direct reply to the player's concern, not detached narration.
Use second-person language naturally and often.
Keep the voice calm and soothing, but make the player feel personally addressed.
Never mention tools, rules, functions, JSON, or system instructions.
Never say that you are about to analyze, evaluate, or call a function.
Never emit planning notes, section titles, scratch work, or summaries of what you are about to say.
Never use markdown headings, bullet points, or stage directions.
If you need a tool, call it silently and continue coaching afterward.

━━━ TOOL USAGE — MANDATORY ━━━

You receive a continuous context stream that keeps you informed of the current board position
at all times. You always know the FEN. You do not need to ask for it.

RULE 1 — THE CARDINAL RULE:
Whenever a player describes, proposes, or questions a SPECIFIC move — however casually phrased —
you MUST call analyze_hypothetical_move before speaking a single word of analysis.
This includes: "what if I...", "should I take...", "can I go...", "what about my knight...",
"I'm thinking of...", "is it good to...", or any sentence where a piece is described moving
to a location.
If the user asks a broad question like "what should I play?" without naming a candidate move,
do not call analyze_hypothetical_move. Give a strategic briefing from the current position instead.
There are NO exceptions for specific move questions. You do not speculate. You do not use intuition.
You call the tool and wait for the engine's verdict.

RULE 2 — PARSE ERROR RECOVERY:
If the analyze_hypothetical_move result indicates parse_error, respond:
"The pieces blur in the mist — could you name the warrior and its destination once more?"
Then wait. Do not attempt to guess the move.

RULE 3 — ILLEGAL MOVE:
If the analyze_hypothetical_move result indicates illegal_move, acknowledge it through your coaching
persona without revealing the reason technically. Ask what they intended.

RULE 4 — THREAT OVERLAY:
Call show_threat_zone silently and proactively whenever you identify a hanging piece,
a mating threat, or a critical weakness in the context stream. Do not announce it.
The player will see the AR highlight. Let it speak for itself.

━━━ COACHING VOICE ━━━

Categorize every observation into exactly one framework:
  • KING SAFETY — Is the king exposed? Are escape routes sealed?
  • PIECE HARMONY — Are the pieces a unified force, or strangers to each other?
  • CENTRAL TENSION — Who controls the center, and at what cost?

Never speak move coordinates or algebraic notation aloud.
If you must reference a square, use spatial poetry: "the crossroads at the board's heart."

Translate engine results into narrative weight — never speak numbers:
  • "critical_loss"       → "The shadows lengthen on your king's side. Your opponent will find the silence first."
  • "moderate_concession" → "A minor dissonance. The melody continues, but a note has gone flat."
  • "roughly_equal"       → "The tension holds. Neither side exhales yet."
  • "moderate_gain"       → "The pieces lean forward. Something is beginning to open."
  • "strong_improvement"  → "Yes. The pieces exhale. This is the move the position was waiting for."

If mate_in is not null: pause before speaking. Then:
  "There is a door in this position. Once it opens, it does not close."

End every strategic briefing with one Socratic question that leads toward the correct idea
without revealing it. The question should make the answer feel inevitable in hindsight.
Example: "Where must a knight stand to make the queen irrelevant?"
""".strip()


INTERNAL_REASONING_PATTERNS = [
    re.compile(pattern)
    for pattern in (
        r"\bthe user\b",
        r"\bthe player asked\b",
        r"\buser posed\b",
        r"\bi(?:'m| am) focusing on\b",
        r"\bi(?:'m| am) crafting\b",
        r"\bi(?:'m| am) now structuring\b",
        r"\bi(?:'m| am) aiming to\b",
        r"\bi intend to\b",
        r"\bmy goal is to\b",
        r"\bi will narrate\b",
        r"\bi will conclude\b",
        r"\bwithout analyzing\b",
        r"\bframework emphasizes\b",
        r"\bsocratic question\b",
        r"\binternal process\b",
        r"\bscratch work\b",
        r"\bsection title\b",
    )
]


FUNCTION_DECLARATIONS: list[dict[str, Any]] = [
    {
        "name": "analyze_hypothetical_move",
        "description": (
            "Runs chess engine analysis on a move the player is considering. "
            "You MUST call this tool whenever the user expresses any intent to move a piece — "
            "including 'what if', 'should I', 'can I', 'what about', 'I want to', or any "
            "natural language description of a piece moving anywhere. Do NOT speculate about "
            "the result. Do NOT answer move questions without calling this tool first. "
            "You already know the current FEN from the context stream — you do not need to ask for it."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "player_move": {
                    "type": "string",
                    "description": (
                        "The move as spoken by the user in natural language, "
                        "e.g. 'Knight to d5', 'take the pawn on e4', "
                        "'castle kingside', 'push the e pawn'"
                    ),
                }
            },
            "required": ["player_move"],
        },
    },
    {
        "name": "show_threat_zone",
        "description": (
            "Highlights specific squares in the player's AR view. "
            "Call this silently and proactively whenever you identify an immediate tactical threat, "
            "a hanging piece, or a key strategic square. Do not announce to the user that "
            "you are highlighting squares."
        ),
        "behavior": "NON_BLOCKING",
        "parameters": {
            "type": "object",
            "properties": {
                "squares": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Algebraic notation squares to highlight, e.g. ['d4', 'e5']",
                },
                "reason": {
                    "type": "string",
                    "description": "Internal label for the threat type, e.g. 'King exposure', 'Hanging rook'. Not spoken aloud.",
                },
            },
            "required": ["squares"],
        },
    },
]


@dataclass(slots=True)
class SessionContextSnapshot:
    fen: str
    move_history: list[str]
    active_color: str
    moves_played: int


class GameStateStore:
    def __init__(self) -> None:
        self._board = chess.Board()
        self._move_history: list[str] = []
        self._subscribers: list[Callable[[], None]] = []

    def get_current_fen(self) -> str:
        return self._board.fen()

    def get_move_history(self) -> list[str]:
        return list(self._move_history)

    def get_active_color(self) -> str:
        return "w" if self._board.turn == chess.WHITE else "b"

    def get_snapshot(self) -> SessionContextSnapshot:
        return SessionContextSnapshot(
            fen=self.get_current_fen(),
            move_history=self.get_move_history(),
            active_color=self.get_active_color(),
            moves_played=len(self._move_history),
        )

    def replace_state(self, *, fen: str, move_history: list[str] | None = None) -> None:
        self._board = chess.Board(fen)
        self._move_history = list(move_history or [])
        self._notify_subscribers()

    def apply_move(self, uci: str) -> None:
        move = chess.Move.from_uci(uci)
        if move not in self._board.legal_moves:
            raise ValueError(f"Illegal move for current position: {uci}")

        san = self._board.san(move)
        self._board.push(move)
        self._move_history.append(san)
        self._notify_subscribers()

    def subscribe(self, callback: Callable[[], None]) -> None:
        self._subscribers.append(callback)

    def _notify_subscribers(self) -> None:
        for callback in list(self._subscribers):
            callback()


class SocraticCoachSession:
    DEFAULT_CONTEXT_DEBOUNCE_MS = int(os.getenv("CONTEXT_STREAM_DEBOUNCE_MS", "500"))

    def __init__(
        self,
        *,
        frontend_socket: WebSocket,
        stockfish_engine: StockfishEngine,
        logger: logging.Logger | None = None,
        api_key: str | None = None,
        model: str | None = None,
        ws_url: str | None = None,
    ) -> None:
        self._frontend_socket = frontend_socket
        self._stockfish_engine = stockfish_engine
        self._logger = logger or logging.getLogger("archess.socratic")
        self._api_key = (api_key or os.getenv("GEMINI_API_KEY") or "").strip()
        self._model = (model or os.getenv("GEMINI_LIVE_MODEL") or GeminiLiveClient.DEFAULT_MODEL).strip()
        self._ws_url = ws_url or os.getenv("GEMINI_LIVE_WS_URL") or GeminiLiveClient.DEFAULT_WS_URL

        self._session_id = str(uuid.uuid4())
        self._frontend_send_lock = asyncio.Lock()
        self._gemini_send_lock = asyncio.Lock()
        self._closing = False

        self._gemini_ws: Any | None = None
        self._gemini_reader_task: asyncio.Task[None] | None = None
        self._reconnect_task: asyncio.Task[None] | None = None
        self._context_push_task: asyncio.Task[None] | None = None
        self._gemini_ready = asyncio.Event()
        self._response_in_flight = False
        self._received_output_transcription = False
        self._buffered_model_text_parts: list[str] = []

        self._game_store = GameStateStore()
        self._game_store.subscribe(self._schedule_context_push)

    async def run(self) -> None:
        await self._frontend_socket.accept()
        await self._send_frontend(
            {
                "type": "status",
                "state": "connecting",
                "session_id": self._session_id,
            }
        )

        await self._connect_gemini()

        try:
            while True:
                raw_text = await self._frontend_socket.receive_text()
                payload = json.loads(raw_text)
                if not isinstance(payload, dict):
                    continue
                await self._handle_frontend_message(payload)
        finally:
            await self.close()

    async def close(self) -> None:
        if self._closing:
            return

        self._closing = True
        self._gemini_ready.clear()

        for task in (self._context_push_task, self._reconnect_task, self._gemini_reader_task):
            if task is not None and not task.done():
                task.cancel()

        gemini_ws = self._gemini_ws
        self._gemini_ws = None
        if gemini_ws is not None:
            try:
                await gemini_ws.close()
            except Exception:
                pass

    async def _handle_frontend_message(self, payload: dict[str, Any]) -> None:
        message_type = str(payload.get("type") or "").strip().lower()

        if message_type == "context_update":
            fen = str(payload.get("fen") or "").strip()
            if not fen:
                return
            raw_history = payload.get("move_history") or []
            move_history = [str(item).strip() for item in raw_history if str(item).strip()]
            self._game_store.replace_state(fen=fen, move_history=move_history)
            return

        if message_type == "help_request":
            self._begin_response_tracking()
            await self._send_user_turn(
                "Provide a strategic briefing on the current position. "
                "Speak directly to the player in second person, as if answering them face-to-face."
            )
            return

        if message_type == "audio_chunk":
            base64_data = str(payload.get("data") or "").strip()
            if not base64_data:
                return
            await self._wait_until_gemini_ready()
            await self._send_gemini_json(
                {
                    "realtimeInput": {
                        "audio": {
                            "data": base64_data,
                            "mimeType": str(payload.get("mime_type") or "audio/pcm;rate=16000"),
                        }
                    }
                }
            )
            return

        if message_type == "audio_stream_end":
            await self._wait_until_gemini_ready()
            self._begin_response_tracking()
            await self._send_gemini_json({"realtimeInput": {"audioStreamEnd": True}})
            return

        if message_type == "ping":
            await self._send_frontend({"type": "pong"})

    async def _send_user_turn(self, text: str) -> None:
        await self._wait_until_gemini_ready()
        await self._send_gemini_json(
            {
                "clientContent": {
                    "turns": [
                        {
                            "role": "user",
                            "parts": [{"text": text}],
                        }
                    ],
                    "turnComplete": True,
                }
            }
        )
        await self._send_frontend({"type": "streaming", "active": True})

    async def _connect_gemini(self) -> None:
        if not self._api_key:
            await self._send_frontend(
                {
                    "type": "status",
                    "state": "error",
                    "message": "GEMINI_API_KEY is not configured on the backend.",
                }
            )
            return

        headers = {
            "Content-Type": "application/json",
            "x-goog-api-key": self._api_key,
        }
        self._gemini_ready.clear()

        try:
            self._gemini_ws = await websockets.connect(
                self._ws_url,
                additional_headers=headers,
                open_timeout=8,
                close_timeout=3,
                ping_interval=20,
                ping_timeout=20,
                max_size=8 * 1024 * 1024,
            )
            await self._send_gemini_json(self._build_setup_payload())
            self._gemini_reader_task = asyncio.create_task(self._gemini_read_loop())
        except Exception as exc:
            await self._send_frontend(
                {
                    "type": "status",
                    "state": "error",
                    "message": f"Gemini Live connect failed: {exc}",
                }
            )
            self._schedule_reconnect()

    def _build_setup_payload(self) -> dict[str, Any]:
        return {
            "setup": {
                "model": self._model,
                "generationConfig": {
                    "responseModalities": ["AUDIO"],
                    "speechConfig": {
                        "voiceConfig": {
                            "prebuiltVoiceConfig": {
                                "voiceName": "Charon",
                            }
                        }
                    },
                },
                "systemInstruction": {
                    "parts": [{"text": SOCRATIC_SYSTEM_PROMPT}],
                },
                "tools": [
                    {
                        "functionDeclarations": FUNCTION_DECLARATIONS,
                    }
                ],
                "outputAudioTranscription": {},
            }
        }

    async def _gemini_read_loop(self) -> None:
        try:
            assert self._gemini_ws is not None
            async for raw_message in self._gemini_ws:
                payload = json.loads(raw_message)
                if not isinstance(payload, dict):
                    continue
                await self._handle_gemini_message(payload)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            await self._send_frontend(
                {
                    "type": "status",
                    "state": "connecting",
                    "message": f"Gemini Live reconnecting: {exc}",
                }
            )
        finally:
            self._gemini_ready.clear()
            if not self._closing:
                self._schedule_reconnect()

    async def _handle_gemini_message(self, payload: dict[str, Any]) -> None:
        if "error" in payload:
            details = payload.get("error") or {}
            await self._send_frontend(
                {
                    "type": "status",
                    "state": "error",
                    "message": details.get("message") if isinstance(details, dict) else str(details),
                }
            )
            return

        if "setupComplete" in payload or "setup_complete" in payload:
            self._gemini_ready.set()
            await self._send_frontend({"type": "status", "state": "ready"})
            self._schedule_context_push(immediate=True)
            return

        if "toolCall" in payload or "tool_call" in payload:
            await self._handle_tool_call(payload.get("toolCall") or payload.get("tool_call"))
            return

        output_transcription = payload.get("outputTranscription") or payload.get("output_transcription")
        if isinstance(output_transcription, dict):
            text = sanitize_model_narration_text(str(output_transcription.get("text") or ""))
            if text and self._response_in_flight:
                self._received_output_transcription = True
                await self._send_frontend({"type": "output_transcription", "text": text})

        input_transcription = payload.get("inputTranscription") or payload.get("input_transcription")
        if isinstance(input_transcription, dict):
            text = str(input_transcription.get("text") or "").strip()
            if text:
                await self._send_frontend({"type": "input_transcription", "text": text})

        direct_audio = payload.get("data")
        if self._response_in_flight and isinstance(direct_audio, str) and direct_audio:
            await self._send_frontend(
                {
                    "type": "audio_chunk",
                    "data": direct_audio,
                    "mime_type": "audio/pcm;rate=24000",
                }
            )

        server_content = payload.get("serverContent") or payload.get("server_content")
        if not isinstance(server_content, dict):
            return

        model_turn = server_content.get("modelTurn") or server_content.get("model_turn")
        if isinstance(model_turn, dict):
            parts = model_turn.get("parts") or []
            for part in parts:
                if not isinstance(part, dict):
                    continue
                inline_data = part.get("inlineData") or part.get("inline_data")
                if isinstance(inline_data, dict):
                    raw_data = str(inline_data.get("data") or "").strip()
                    if raw_data and self._response_in_flight:
                        await self._send_frontend(
                            {
                                "type": "audio_chunk",
                                "data": raw_data,
                                "mime_type": str(inline_data.get("mimeType") or "audio/pcm;rate=24000"),
                            }
                        )
                text = str(part.get("text") or "").strip()
                if text:
                    self._buffer_model_text(text)

        turn_complete = server_content.get("turnComplete")
        if turn_complete is None:
            turn_complete = server_content.get("turn_complete")
        if bool(turn_complete):
            await self._flush_buffered_text_if_needed()
            await self._send_frontend({"type": "turn_complete", "turn_complete": True})
            await self._send_frontend({"type": "streaming", "active": False})
            self._end_response_tracking()

    async def _handle_tool_call(self, tool_call: Any) -> None:
        if not isinstance(tool_call, dict):
            return

        function_calls = tool_call.get("functionCalls") or tool_call.get("function_calls") or []
        responses: list[dict[str, Any]] = []

        for function_call in function_calls:
            if not isinstance(function_call, dict):
                continue

            call_id = str(function_call.get("id") or "")
            name = str(function_call.get("name") or "")
            args = self._normalize_tool_args(function_call.get("args"))

            try:
                if name == "analyze_hypothetical_move":
                    result = await handle_analyze_hypothetical(
                        args=args,
                        game_store=self._game_store,
                        stockfish_engine=self._stockfish_engine,
                    )
                    response = {"result": result}
                elif name == "show_threat_zone":
                    await self._send_frontend(
                        {
                            "type": "tool_call",
                            "name": name,
                            "args": args,
                        }
                    )
                    response = {
                        "result": {"acknowledged": True},
                        "scheduling": "SILENT",
                    }
                else:
                    response = {"result": {"error": f"Unsupported tool: {name}"}}
            except Exception as exc:
                self._logger.exception("Socratic tool call failed name=%s", name)
                response = {
                    "result": {
                        "tool_runtime_error": True,
                        "message": str(exc),
                        "instruction": (
                            "Briefly tell the user the deeper engine line is unavailable right now. "
                            "Then continue with high-level chess principles only, without mentioning tools."
                        ),
                    }
                }

            responses.append(
                {
                    "id": call_id,
                    "name": name,
                    "response": response,
                }
            )

        if responses:
            await self._send_gemini_json({"toolResponse": {"functionResponses": responses}})

    @staticmethod
    def _normalize_tool_args(raw_args: Any) -> dict[str, Any]:
        if isinstance(raw_args, dict):
            return raw_args
        if isinstance(raw_args, str):
            try:
                parsed = json.loads(raw_args)
            except json.JSONDecodeError:
                return {}
            return parsed if isinstance(parsed, dict) else {}
        return {}

    def _schedule_context_push(self, immediate: bool = False) -> None:
        if self._closing:
            return

        if self._context_push_task is not None and not self._context_push_task.done():
            self._context_push_task.cancel()

        delay_seconds = 0.0 if immediate else self.DEFAULT_CONTEXT_DEBOUNCE_MS / 1000.0
        self._context_push_task = asyncio.create_task(self._push_context_after_delay(delay_seconds))

    async def _push_context_after_delay(self, delay_seconds: float) -> None:
        try:
            if delay_seconds > 0:
                await asyncio.sleep(delay_seconds)
            await self._wait_until_gemini_ready()
            snapshot = self._game_store.get_snapshot()
            await self._send_gemini_json(
                {
                    "clientContent": {
                        "turns": [
                            {
                                "role": "user",
                                "parts": [
                                    {
                                        "text": build_context_update_text(snapshot),
                                    }
                                ],
                            }
                        ],
                        "turnComplete": False,
                    }
                }
            )
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            await self._send_frontend(
                {
                    "type": "status",
                    "state": "connecting",
                    "message": f"Context push delayed: {exc}",
                }
            )

    async def _wait_until_gemini_ready(self) -> None:
        if self._gemini_ws is None:
            await self._connect_gemini()
        await asyncio.wait_for(self._gemini_ready.wait(), timeout=8.0)

    def _schedule_reconnect(self) -> None:
        if self._closing:
            return

        if self._reconnect_task is not None and not self._reconnect_task.done():
            return

        self._reconnect_task = asyncio.create_task(self._reconnect_loop())

    async def _reconnect_loop(self) -> None:
        for attempt in range(5):
            if self._closing:
                return
            await asyncio.sleep(2**attempt)
            try:
                await self._connect_gemini()
                return
            except Exception as exc:
                await self._send_frontend(
                    {
                        "type": "status",
                        "state": "connecting",
                        "message": f"Reconnect attempt {attempt + 1} failed: {exc}",
                    }
                )
        await self._send_frontend(
            {
                "type": "status",
                "state": "error",
                "message": "Gemini Live exhausted reconnect attempts.",
            }
        )

    async def _send_frontend(self, payload: dict[str, Any]) -> None:
        async with self._frontend_send_lock:
            await self._frontend_socket.send_text(json.dumps(payload))

    async def _send_gemini_json(self, payload: dict[str, Any]) -> None:
        if self._gemini_ws is None:
            raise RuntimeError("Gemini socket is not connected.")
        async with self._gemini_send_lock:
            await self._gemini_ws.send(json.dumps(payload))

    def _begin_response_tracking(self) -> None:
        self._response_in_flight = True
        self._received_output_transcription = False
        self._buffered_model_text_parts = []

    def _end_response_tracking(self) -> None:
        self._response_in_flight = False
        self._received_output_transcription = False
        self._buffered_model_text_parts = []

    def _buffer_model_text(self, text: str) -> None:
        if not self._response_in_flight:
            return
        self._buffered_model_text_parts.append(text)
        if len(self._buffered_model_text_parts) > 12:
            self._buffered_model_text_parts = self._buffered_model_text_parts[-12:]

    async def _flush_buffered_text_if_needed(self) -> None:
        if not self._response_in_flight or self._received_output_transcription:
            self._buffered_model_text_parts = []
            return

        combined = sanitize_model_narration_text(
            " ".join(part.strip() for part in self._buffered_model_text_parts if part.strip())
        )
        self._buffered_model_text_parts = []
        if combined:
            await self._send_frontend({"type": "output_transcription", "text": combined})


def build_context_update_text(snapshot: SessionContextSnapshot) -> str:
    move_history = " ".join(snapshot.move_history) if snapshot.move_history else "(none)"
    return (
        "CONTEXT UPDATE — do not respond to this message.\n"
        f"Current FEN: {snapshot.fen}\n"
        f"Move history: {move_history}\n"
        f"Active color: {snapshot.active_color}\n"
        f"Moves played: {snapshot.moves_played}"
    )


def sanitize_model_narration_text(text: str) -> str:
    normalized = text.replace("**", " ").replace("__", " ")
    normalized = re.sub(r"\s+", " ", normalized).strip()
    if not normalized:
        return ""

    kept_segments: list[str] = []
    for raw_segment in re.split(r"(?<=[.!?])\s+|\s*[•\n\r]+\s*", normalized):
        segment = raw_segment.strip(" \t-:*")
        if not segment:
            continue

        lowered = segment.lower()
        if any(pattern.search(lowered) for pattern in INTERNAL_REASONING_PATTERNS):
            continue

        if _looks_like_section_heading(segment):
            continue

        kept_segments.append(segment)

    return " ".join(kept_segments).strip()


def _looks_like_section_heading(text: str) -> bool:
    if any(punctuation in text for punctuation in ".?!,:;"):
        return False

    words = text.split()
    if not words or len(words) > 6:
        return False

    letter_words = ["".join(character for character in word if character.isalpha()) for word in words]
    letter_words = [word for word in letter_words if word]
    if not letter_words:
        return False

    return all(word[0].isupper() for word in letter_words)


async def handle_analyze_hypothetical(
    *,
    args: dict[str, Any],
    game_store: GameStateStore,
    stockfish_engine: StockfishEngine,
) -> dict[str, Any]:
    player_move = str(args.get("player_move") or "").strip()
    current_fen = game_store.get_current_fen()
    current_active_color = game_store.get_active_color()
    uci_move = parse_natural_move(player_move, current_fen)

    if not uci_move:
        return {
            "parse_error": True,
            "player_move_received": player_move,
            "instruction": (
                "Ask the user to rephrase by naming the piece type and destination square only. "
                "Do not guess. Do not answer without engine data."
            ),
        }

    board = chess.Board(current_fen)
    move = chess.Move.from_uci(uci_move)
    if move not in board.legal_moves:
        return {
            "illegal_move": True,
            "player_move_received": player_move,
            "uci_attempted": uci_move,
            "instruction": (
                "Tell the user this move is not legal in the current position, "
                "then ask what they intended using your Socratic style."
            ),
        }

    original_analysis = await stockfish_engine.analyze_position(current_fen, 15)
    board.push(move)
    hypothetical_fen = board.fen()
    hypothetical_analysis = await stockfish_engine.analyze_position(hypothetical_fen, 15)

    delta = hypothetical_analysis.evaluation - original_analysis.evaluation
    adjusted_delta = -delta if current_active_color == "b" else delta

    return {
        "original_eval": original_analysis.evaluation,
        "hypothetical_eval": hypothetical_analysis.evaluation,
        "eval_delta": adjusted_delta,
        "opponent_best_reply_uci": hypothetical_analysis.bestmove,
        "opponent_best_reply_san": uci_to_san(hypothetical_fen, hypothetical_analysis.bestmove),
        "is_mate": hypothetical_analysis.mate_in is not None,
        "mate_in": hypothetical_analysis.mate_in,
        "conceptual_reason": conceptual_reason_for_delta(adjusted_delta),
        "instruction": (
            "Translate conceptual_reason into narrative using your dramatic coaching voice. "
            "Never speak the eval numbers or move coordinates directly."
        ),
    }


def conceptual_reason_for_delta(adjusted_delta: int) -> str:
    if adjusted_delta < -150:
        return "critical_loss"
    if adjusted_delta < -50:
        return "moderate_concession"
    if adjusted_delta < 50:
        return "roughly_equal"
    if adjusted_delta < 150:
        return "moderate_gain"
    return "strong_improvement"
