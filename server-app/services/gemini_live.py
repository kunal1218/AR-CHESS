from __future__ import annotations

import asyncio
import inspect
import json
import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Callable

import websockets
from websockets.protocol import State

_UNSET = object()


class GeminiLiveConfigurationError(RuntimeError):
    """Raised when Gemini Live configuration is missing or invalid."""


class GeminiLiveConnectionError(RuntimeError):
    """Raised when Gemini Live is unavailable for a turn."""


class GeminiLiveBusyError(RuntimeError):
    """Raised when too many turns are queued for the shared session."""


@dataclass
class _TurnBuffer:
    done: asyncio.Future[str]
    metadata: dict[str, Any] | None = None
    chunks: list[str] = field(default_factory=list)


class GeminiLiveClient:
    DISCONNECTED = "DISCONNECTED"
    CONNECTING = "CONNECTING"
    CONNECTED = "CONNECTED"
    ERROR = "ERROR"
    DEFAULT_MODEL = "models/gemini-2.5-flash-native-audio-preview-12-2025"
    SHUT_DOWN_MODELS = frozenset(
        {
            "gemini-2.0-flash-live-001",
            "gemini-live-2.5-flash-preview",
        }
    )

    DEFAULT_WS_URL = (
        "wss://generativelanguage.googleapis.com/ws/"
        "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    )

    def __init__(
        self,
        *,
        api_key: str | None,
        model: str,
        system_prompt: str,
        generation_config: dict[str, Any] | None = None,
        ws_url: str | None = None,
        logger: logging.Logger | None = None,
        max_queued_turns: int = 2,
    ) -> None:
        self._api_key = (api_key or "").strip()
        self._model = model.strip()
        self._system_prompt = system_prompt
        self._generation_config = generation_config or {
            "temperature": 0.95,
            "top_p": 0.9,
            "top_k": 32,
            "max_output_tokens": 64,
        }
        self._ws_url = ws_url or self.DEFAULT_WS_URL
        self._logger = logger or logging.getLogger("archess.gemini.live")
        self._max_queued_turns = max_queued_turns

        self._connect_lock = asyncio.Lock()
        self._turn_lock = asyncio.Lock()

        self._ws: Any | None = None
        self._reader_task: asyncio.Task[None] | None = None
        self._reconnect_task: asyncio.Task[None] | None = None
        self._setup_future: asyncio.Future[bool] | None = None

        self._current_turn: _TurnBuffer | None = None
        self._queued_turns = 0

        self._manual_disconnect = False
        self._terminal_error = False
        self._partial_callback: Callable[[str, dict[str, Any] | None], Any] | None = None

        self._state = self.DISCONNECTED
        self._state_since = datetime.now(timezone.utc)
        self._last_error: str | None = None

    @property
    def is_configured(self) -> bool:
        return bool(self._api_key)

    def set_partial_callback(self, callback: Callable[[str, dict[str, Any] | None], Any] | None) -> None:
        self._partial_callback = callback

    def get_status(self) -> dict[str, Any]:
        return {
            "state": self._state,
            "lastError": self._last_error,
            "since": self._state_since.isoformat(),
        }

    def ensure_connection_background(self) -> None:
        if self._is_socket_open() or self._state == self.CONNECTING:
            return
        if not self.is_configured:
            self._set_status(self.ERROR, "GEMINI_API_KEY is not configured on the backend.")
            return
        self._schedule_reconnect_if_needed()

    async def connect(self) -> None:
        if not self.is_configured:
            self._set_status(self.ERROR, "GEMINI_API_KEY is not configured on the backend.")
            raise GeminiLiveConfigurationError("GEMINI_API_KEY is not configured on the backend.")

        self._validate_live_model()

        if self._is_socket_open():
            return

        async with self._connect_lock:
            if self._is_socket_open():
                return

            self._manual_disconnect = False
            self._set_status(self.CONNECTING)

            headers = {
                "Content-Type": "application/json",
                "x-goog-api-key": self._api_key,
            }

            try:
                self._ws = await websockets.connect(
                    self._ws_url,
                    additional_headers=headers,
                    open_timeout=8,
                    close_timeout=3,
                    ping_interval=20,
                    ping_timeout=20,
                    max_size=8 * 1024 * 1024,
                )
                self._logger.info("Gemini Live socket open model=%s", self._model)

                self._setup_future = asyncio.get_running_loop().create_future()
                self._reader_task = asyncio.create_task(self._read_loop())

                await self._send_json(self._build_setup_payload())
                self._logger.info("Gemini Live setup sent")

                try:
                    await asyncio.wait_for(self._setup_future, timeout=8)
                except asyncio.TimeoutError:
                    # Live can still be usable before explicit setup ack appears.
                    self._logger.warning("Gemini Live setup ack timeout; continuing with active session")
                    self._set_status(self.CONNECTED)

                self._terminal_error = False
                self._set_status(self.CONNECTED)
            except Exception as exc:
                message = self._error_message(exc)
                self._logger.error("Gemini Live connect failed: %s", message)
                await self._close_socket(best_effort=True)
                if self._is_terminal_error(message):
                    self._terminal_error = True
                    self._set_status(self.ERROR, message)
                else:
                    self._set_status(self.DISCONNECTED, message)
                raise GeminiLiveConnectionError(message) from exc

    async def disconnect(self) -> None:
        self._manual_disconnect = True
        if self._reconnect_task and not self._reconnect_task.done():
            self._reconnect_task.cancel()
        await self._close_socket(best_effort=True)
        self._set_status(self.DISCONNECTED)

    async def send_turn_text(self, text: str, metadata: dict[str, Any] | None = None) -> None:
        await self.connect()
        packet_text = self._build_state_narrative_text(text, metadata)
        await self._send_client_content(
            packet_text,
            metadata=metadata,
            turn_complete=False,
        )

    async def send_turn_complete(self) -> None:
        await self.connect()
        await self._send_json(self._build_client_content_payload("", turn_complete=True))

    async def request_response(self) -> None:
        await self.send_turn_complete()

    async def run_turn(
        self,
        text: str,
        *,
        metadata: dict[str, Any] | None = None,
        timeout_seconds: float = 12,
    ) -> str:
        if self._turn_lock.locked() and self._queued_turns >= self._max_queued_turns:
            raise GeminiLiveBusyError("Gemini Live turn queue is full. Try again in a moment.")

        self._queued_turns += 1
        try:
            async with self._turn_lock:
                await self.connect()
                loop = asyncio.get_running_loop()
                done_future: asyncio.Future[str] = loop.create_future()
                self._current_turn = _TurnBuffer(done=done_future, metadata=metadata)
                packet_text = self._build_state_narrative_text(text, metadata)

                await self._send_client_content(
                    packet_text,
                    metadata=metadata,
                    turn_complete=True,
                )

                try:
                    response_text = await asyncio.wait_for(done_future, timeout=timeout_seconds)
                except asyncio.TimeoutError as exc:
                    self._current_turn = None
                    self._set_status(self.DISCONNECTED, "Timed out waiting for Gemini Live turn completion.")
                    self._schedule_reconnect_if_needed()
                    raise GeminiLiveConnectionError("Timed out waiting for Gemini Live turn completion.") from exc

                return response_text
        finally:
            self._queued_turns = max(0, self._queued_turns - 1)

    async def _send_client_content(
        self,
        text: str,
        *,
        metadata: dict[str, Any] | None,
        turn_complete: bool,
    ) -> None:
        await self._send_json(self._build_client_content_payload(text, turn_complete=turn_complete))
        self._logger.info(
            "Gemini Live turn text sent chars=%s turn_complete=%s",
            len(text),
            turn_complete,
        )
        _ = metadata

    def _build_setup_payload(self) -> dict[str, Any]:
        return {
            "setup": {
                "model": self._model,
                "generationConfig": self._generation_config,
                "systemInstruction": {
                    "parts": [{"text": self._system_prompt}],
                },
            }
        }

    def _build_client_content_payload(self, text: str, *, turn_complete: bool) -> dict[str, Any]:
        turns: list[dict[str, Any]] = []
        if text:
            turns.append(
                {
                    "role": "user",
                    "parts": [{"text": text}],
                }
            )

        return {
            "clientContent": {
                "turns": turns,
                "turnComplete": turn_complete,
            }
        }

    def _build_state_narrative_text(self, text: str, metadata: dict[str, Any] | None) -> str:
        metadata = metadata or {}
        current_fen = str(metadata.get("current_fen") or metadata.get("fen") or "").strip()
        recent_history = str(metadata.get("recent_history") or metadata.get("recentHistory") or "").strip()
        query = text.strip()

        segments: list[str] = []
        if current_fen:
            segments.append(f"Current FEN: {current_fen}")
        if recent_history:
            segments.append(f"Recent Sequence: {recent_history}")
        if query:
            segments.append(f"User Query: {query}")

        return " | ".join(segments) or query

    async def _send_json(self, payload: dict[str, Any]) -> None:
        if not self._is_socket_open():
            raise GeminiLiveConnectionError("Gemini Live socket is not connected.")

        try:
            await self._ws.send(json.dumps(payload))
        except Exception as exc:
            message = self._error_message(exc)
            self._logger.error("Gemini Live send failed: %s", message)
            self._set_status(self.DISCONNECTED, message)
            self._schedule_reconnect_if_needed()
            raise GeminiLiveConnectionError(message) from exc

    async def _read_loop(self) -> None:
        try:
            while self._is_socket_open():
                raw = await self._ws.recv()
                data = json.loads(raw)
                if not isinstance(data, dict):
                    continue
                await self._handle_server_message(data)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            message = self._error_message(exc)
            if self._manual_disconnect:
                self._logger.info("Gemini Live reader stopped after manual disconnect")
            else:
                self._logger.warning("Gemini Live reader stopped: %s", message)
                if self._setup_future and not self._setup_future.done():
                    self._setup_future.set_exception(GeminiLiveConnectionError(message))
                if self._is_terminal_error(message):
                    self._terminal_error = True
                    self._set_status(self.ERROR, message)
                else:
                    self._set_status(self.DISCONNECTED, message)
                    self._schedule_reconnect_if_needed()
                self._fail_active_turn(GeminiLiveConnectionError(message))
        finally:
            self._reader_task = None
            await self._close_socket(best_effort=True)

    async def _handle_server_message(self, message: dict[str, Any]) -> None:
        if "error" in message and isinstance(message["error"], dict):
            error = message["error"]
            code = error.get("code")
            details = error.get("message") or json.dumps(error)
            self._logger.error("Gemini Live server error code=%s message=%s", code, details)

            if self._setup_future and not self._setup_future.done():
                self._setup_future.set_exception(GeminiLiveConnectionError(details))

            self._fail_active_turn(GeminiLiveConnectionError(details))

            if self._is_terminal_error(details, code=code):
                self._terminal_error = True
                self._set_status(self.ERROR, details)
            else:
                self._set_status(self.DISCONNECTED, details)
                self._schedule_reconnect_if_needed()
            return

        if "setupComplete" in message or "setup_complete" in message:
            self._logger.info("Gemini Live setup acknowledged")
            if self._setup_future and not self._setup_future.done():
                self._setup_future.set_result(True)
            self._set_status(self.CONNECTED)

        server_content = message.get("serverContent") or message.get("server_content")
        if not isinstance(server_content, dict):
            return

        if self._setup_future and not self._setup_future.done():
            # Some responses start with server content before explicit setupComplete.
            self._setup_future.set_result(True)
            self._logger.info("Gemini Live first server content received")

        self._set_status(self.CONNECTED)

        model_turn = server_content.get("modelTurn") or server_content.get("model_turn")
        if isinstance(model_turn, dict):
            parts = model_turn.get("parts") or []
            for part in parts:
                if not isinstance(part, dict):
                    continue
                text = part.get("text")
                if not isinstance(text, str) or not text:
                    continue
                if self._current_turn is not None:
                    self._current_turn.chunks.append(text)
                if self._partial_callback is not None:
                    callback_result = self._partial_callback(
                        text,
                        self._current_turn.metadata if self._current_turn else None,
                    )
                    if inspect.isawaitable(callback_result):
                        await callback_result

        turn_complete = server_content.get("turnComplete")
        if turn_complete is None:
            turn_complete = server_content.get("turn_complete")
        if bool(turn_complete):
            self._finish_active_turn()

    def _finish_active_turn(self) -> None:
        if self._current_turn is None:
            return

        combined = "".join(self._current_turn.chunks).strip()
        if not self._current_turn.done.done():
            self._current_turn.done.set_result(combined)
        self._current_turn = None

    def _fail_active_turn(self, error: Exception) -> None:
        if self._current_turn is None:
            return
        if not self._current_turn.done.done():
            self._current_turn.done.set_exception(error)
        self._current_turn = None

    async def _close_socket(self, *, best_effort: bool) -> None:
        ws = self._ws
        self._ws = None
        if ws is not None:
            try:
                await ws.close()
                self._logger.info("Gemini Live socket closed")
            except Exception as exc:
                if not best_effort:
                    raise
                self._logger.debug("Gemini Live close error ignored: %s", self._error_message(exc))

    def _schedule_reconnect_if_needed(self) -> None:
        if self._manual_disconnect or self._terminal_error or not self.is_configured:
            return

        if self._reconnect_task and not self._reconnect_task.done():
            return

        self._reconnect_task = asyncio.create_task(self._reconnect_loop())

    async def _reconnect_loop(self) -> None:
        attempt = 0
        while not self._manual_disconnect and not self._terminal_error and not self._is_socket_open():
            delay = min(10.0, 0.25 * (2**attempt))
            self._set_status(self.CONNECTING, self._last_error)
            self._logger.info(
                "Gemini Live reconnect attempt=%s delay_ms=%s",
                attempt + 1,
                int(delay * 1000),
            )
            await asyncio.sleep(delay)
            try:
                await self.connect()
                return
            except GeminiLiveConfigurationError:
                self._terminal_error = True
                self._set_status(self.ERROR, "GEMINI_API_KEY is not configured on the backend.")
                return
            except GeminiLiveConnectionError as exc:
                if self._is_terminal_error(str(exc)):
                    self._terminal_error = True
                    self._set_status(self.ERROR, str(exc))
                    return
                attempt += 1
                continue

    def _is_socket_open(self) -> bool:
        if self._ws is None:
            return False

        if hasattr(self._ws, "closed"):
            return not bool(getattr(self._ws, "closed"))

        return getattr(self._ws, "state", None) == State.OPEN

    def _set_status(self, state: str, last_error: str | None | object = _UNSET) -> None:
        changed = state != self._state

        if last_error is not _UNSET:
            if isinstance(last_error, str):
                if self._last_error != last_error:
                    changed = True
                self._last_error = last_error
            else:
                # Clear error if an explicit non-string sentinel is passed.
                self._last_error = None
                changed = True
        elif state == self.CONNECTED:
            if self._last_error is not None:
                changed = True
            self._last_error = None

        self._state = state
        if changed:
            self._state_since = datetime.now(timezone.utc)
            self._logger.info("Gemini Live status=%s last_error=%s", state, self._last_error)

    def _is_terminal_error(self, message: str, code: Any | None = None) -> bool:
        if isinstance(code, int) and code in {400, 401, 403}:
            return True

        lowered = message.lower()
        if "api key" in lowered and any(
            marker in lowered for marker in ("expired", "expir", "invalid", "revoked", "disabled")
        ):
            return True

        if "invalid frame payload data" in lowered and any(
            marker in lowered for marker in ("api key", "credential", "auth", "unauth")
        ):
            return True

        return any(
            marker in lowered
            for marker in (
                "api key not valid",
                "api key expired",
                "permission_denied",
                "unauthenticated",
                "forbidden",
                "http 401",
                "http 403",
                "invalid argument",
                "invalid setup",
                "malformed",
            )
        )

    def _error_message(self, exc: Exception) -> str:
        text = str(exc).strip()
        return text or exc.__class__.__name__

    def _validate_live_model(self) -> None:
        normalized = self._normalized_model_name(self._model)

        if not normalized:
            raise GeminiLiveConfigurationError("GEMINI_LIVE_MODEL is empty.")

        if normalized in self.SHUT_DOWN_MODELS:
            raise GeminiLiveConfigurationError(
                f"GEMINI_LIVE_MODEL '{self._model}' is shut down. "
                f"Use {self.DEFAULT_MODEL} for Gemini Live."
            )

        if normalized.startswith("gemini-3-"):
            raise GeminiLiveConfigurationError(
                f"GEMINI_LIVE_MODEL '{self._model}' is a Gemini 3 model, but Gemini 3 currently "
                "does not support the Live API. Keep Gemini Live on "
                f"{self.DEFAULT_MODEL} and use Gemini 3 only with generateContent-style endpoints."
            )

    @staticmethod
    def _normalized_model_name(model: str) -> str:
        normalized = model.strip()
        if normalized.startswith("models/"):
            normalized = normalized.removeprefix("models/")
        return normalized
