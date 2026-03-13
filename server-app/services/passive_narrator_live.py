from __future__ import annotations

import asyncio
import json
import logging
import os
from typing import Any

import websockets
from fastapi import WebSocket

from services.gemini_live import GeminiLiveClient


PASSIVE_NARRATOR_READ_SYSTEM_PROMPT = """
You are a cinematic chess narrator performing already-written lines aloud.
For each user turn, read the supplied narrator line exactly as written.
Do not add, remove, paraphrase, explain, preface, summarize, or continue past the supplied line.
Keep the delivery calm, warm, observant, and natural to listen to.
Return audio and matching transcription only.
""".strip()


class PassiveNarratorLiveSession:
    def __init__(
        self,
        *,
        frontend_socket: WebSocket,
        logger: logging.Logger | None = None,
        api_key: str | None = None,
        model: str | None = None,
        ws_url: str | None = None,
    ) -> None:
        self._frontend_socket = frontend_socket
        self._logger = logger or logging.getLogger("archess.passive_narrator")
        self._api_key = (api_key or os.getenv("GEMINI_API_KEY") or "").strip()
        self._model = (model or os.getenv("GEMINI_LIVE_MODEL") or GeminiLiveClient.DEFAULT_MODEL).strip()
        self._ws_url = ws_url or os.getenv("GEMINI_LIVE_WS_URL") or GeminiLiveClient.DEFAULT_WS_URL

        self._frontend_send_lock = asyncio.Lock()
        self._gemini_send_lock = asyncio.Lock()
        self._closing = False
        self._response_in_flight = False

        self._gemini_ws: Any | None = None
        self._gemini_reader_task: asyncio.Task[None] | None = None
        self._reconnect_task: asyncio.Task[None] | None = None
        self._gemini_ready = asyncio.Event()

    async def run(self) -> None:
        await self._frontend_socket.accept()
        await self._send_frontend({"type": "status", "state": "connecting"})
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

        for task in (self._reconnect_task, self._gemini_reader_task):
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

        if message_type == "narrate_line":
            line = " ".join(str(payload.get("text") or "").split()).strip()
            if not line:
                return
            if self._response_in_flight:
                await self._send_frontend({"type": "busy", "message": "Narrator audio is already in flight."})
                return
            self._response_in_flight = True
            await self._send_frontend({"type": "streaming", "active": True})
            try:
                await self._send_user_turn(line)
            except Exception as exc:
                self._response_in_flight = False
                await self._send_frontend({"type": "streaming", "active": False})
                await self._send_frontend(
                    {
                        "type": "status",
                        "state": "error",
                        "message": f"Gemini passive narrator send failed: {exc}",
                    }
                )
            return

        if message_type == "ping":
            await self._send_frontend({"type": "pong"})

    async def _send_user_turn(self, line: str) -> None:
        await self._wait_until_gemini_ready()
        await self._send_gemini_json(
            {
                "clientContent": {
                    "turns": [
                        {
                            "role": "user",
                            "parts": [
                                {
                                    "text": (
                                        "Speak the following narrator line aloud exactly as written. "
                                        "Do not add or change any words.\n"
                                        f"Line: {line}"
                                    )
                                }
                            ],
                        }
                    ],
                    "turnComplete": True,
                }
            }
        )

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
                    "message": f"Gemini passive narrator connect failed: {exc}",
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
                                "voiceName": os.getenv("GEMINI_PASSIVE_NARRATOR_VOICE_NAME", "Charon"),
                            }
                        }
                    },
                },
                "systemInstruction": {
                    "parts": [{"text": PASSIVE_NARRATOR_READ_SYSTEM_PROMPT}],
                },
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
                    "message": f"Gemini passive narrator reconnecting: {exc}",
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
            self._response_in_flight = False
            await self._send_frontend({"type": "streaming", "active": False})
            return

        if "setupComplete" in payload or "setup_complete" in payload:
            self._gemini_ready.set()
            await self._send_frontend({"type": "status", "state": "ready"})
            return

        output_transcription = payload.get("outputTranscription") or payload.get("output_transcription")
        if isinstance(output_transcription, dict):
            text = str(output_transcription.get("text") or "").strip()
            if text:
                self._gemini_ready.set()
                await self._send_frontend({"type": "output_transcription", "text": text})

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

        self._gemini_ready.set()

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
                    await self._send_frontend({"type": "output_transcription", "text": text})

        turn_complete = server_content.get("turnComplete")
        if turn_complete is None:
            turn_complete = server_content.get("turn_complete")
        if bool(turn_complete):
            self._response_in_flight = False
            await self._send_frontend({"type": "turn_complete", "turn_complete": True})
            await self._send_frontend({"type": "streaming", "active": False})

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
                        "message": f"Passive narrator reconnect attempt {attempt + 1} failed: {exc}",
                    }
                )

        await self._send_frontend(
            {
                "type": "status",
                "state": "error",
                "message": "Gemini passive narrator exhausted reconnect attempts.",
            }
        )

    async def _send_frontend(self, payload: dict[str, Any]) -> None:
        async with self._frontend_send_lock:
            await self._frontend_socket.send_text(json.dumps(payload))

    async def _send_gemini_json(self, payload: dict[str, Any]) -> None:
        if self._gemini_ws is None:
            raise RuntimeError("Gemini passive narrator socket is not connected.")
        async with self._gemini_send_lock:
            await self._gemini_ws.send(json.dumps(payload))
