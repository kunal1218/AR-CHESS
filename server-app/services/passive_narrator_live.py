from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import tempfile
import wave
from array import array
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import websockets
from fastapi import WebSocket

from services.gemini_live import GeminiLiveClient


PASSIVE_NARRATOR_READ_SYSTEM_PROMPT = """
You are performing already-written chess voice lines aloud.
For each user turn, read the supplied line exactly as written.
Do not add, remove, paraphrase, explain, preface, summarize, or continue past the supplied line.
Adjust delivery to the supplied speaker role metadata when present.
Return audio and matching transcription only.
""".strip()

PIPER_PIECE_VOICE_KEYS = ("pawn", "knight", "bishop", "rook", "queen", "king")


@dataclass(frozen=True)
class PiperVoiceSpec:
    model: str
    speaker_id: int | None = None


@dataclass(frozen=True)
class PassiveLocalPiperConfig:
    binary_path: str
    narrator_voice: PiperVoiceSpec
    piece_default_voice: PiperVoiceSpec
    piece_voices: dict[str, PiperVoiceSpec]

    @classmethod
    def from_env(cls, logger: logging.Logger) -> PassiveLocalPiperConfig | None:
        backend = (os.getenv("PASSIVE_LIVE_TTS_BACKEND") or "gemini").strip().lower()
        if backend != "piper":
            return None

        binary_path = (os.getenv("PIPER_BINARY_PATH") or "piper").strip() or "piper"
        piece_default_voice = _piper_voice_spec_from_env("PIECE_DEFAULT")
        narrator_voice = _piper_voice_spec_from_env(
            "NARRATOR",
            fallback_model=piece_default_voice.model if piece_default_voice else None,
            fallback_speaker_id=piece_default_voice.speaker_id if piece_default_voice else None,
        )

        if narrator_voice is None and piece_default_voice is None:
            logger.warning(
                "PASSIVE_LIVE_TTS_BACKEND=piper, but no Piper narrator or piece default voice is configured. "
                "Falling back to Gemini passive live."
            )
            return None

        narrator_voice = narrator_voice or piece_default_voice
        assert narrator_voice is not None
        piece_default_voice = piece_default_voice or narrator_voice

        piece_voices: dict[str, PiperVoiceSpec] = {}
        for key in PIPER_PIECE_VOICE_KEYS:
            piece_voices[key] = _piper_voice_spec_from_env(
                key.upper(),
                fallback_model=piece_default_voice.model,
                fallback_speaker_id=piece_default_voice.speaker_id,
            ) or piece_default_voice

        return cls(
            binary_path=binary_path,
            narrator_voice=narrator_voice,
            piece_default_voice=piece_default_voice,
            piece_voices=piece_voices,
        )

    def resolve_voice(self, speaker_role: str, speaker_name: str | None) -> PiperVoiceSpec:
        if speaker_role == "narrator":
            return self.narrator_voice
        voice_key = _normalize_piece_voice_key(speaker_name)
        return self.piece_voices.get(voice_key or "", self.piece_default_voice)


class PassiveLocalPiperSynthesizer:
    _chunk_size_bytes = 8192

    def __init__(self, config: PassiveLocalPiperConfig, logger: logging.Logger | None = None) -> None:
        self._config = config
        self._logger = logger or logging.getLogger("archess.passive_piper")

    async def synthesize(self, text: str, *, speaker_role: str, speaker_name: str | None) -> tuple[int, bytes]:
        voice = self._config.resolve_voice(speaker_role, speaker_name)
        with tempfile.TemporaryDirectory(prefix="archess_piper_") as temp_dir:
            output_path = Path(temp_dir) / "line.wav"
            args = [
                self._config.binary_path,
                "--model",
                voice.model,
                "--output_file",
                str(output_path),
            ]
            if voice.speaker_id is not None:
                args.extend(["--speaker", str(voice.speaker_id)])

            process = await asyncio.create_subprocess_exec(
                *args,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE,
            )
            _, stderr = await process.communicate((text.strip() + "\n").encode("utf-8"))
            if process.returncode != 0:
                error_text = stderr.decode("utf-8", errors="ignore").strip() or "Piper synthesis failed."
                raise RuntimeError(error_text)

            return _load_wav_as_pcm(output_path)

    async def stream_to_frontend(
        self,
        *,
        frontend_send: Any,
        text: str,
        speaker_role: str,
        speaker_name: str | None,
    ) -> None:
        sample_rate, pcm_bytes = await self.synthesize(
            text,
            speaker_role=speaker_role,
            speaker_name=speaker_name,
        )
        await frontend_send({"type": "output_transcription", "text": text})
        mime_type = f"audio/pcm;rate={sample_rate}"
        for chunk in _iter_pcm_chunks(pcm_bytes, chunk_size_bytes=self._chunk_size_bytes):
            await frontend_send(
                {
                    "type": "audio_chunk",
                    "data": base64.b64encode(chunk).decode("ascii"),
                    "mime_type": mime_type,
                }
            )


def _piper_voice_spec_from_env(
    slot: str,
    *,
    fallback_model: str | None = None,
    fallback_speaker_id: int | None = None,
) -> PiperVoiceSpec | None:
    model = (os.getenv(f"PIPER_VOICE_{slot}_MODEL") or fallback_model or "").strip()
    if not model:
        return None

    speaker_raw = (os.getenv(f"PIPER_VOICE_{slot}_SPEAKER") or "").strip()
    if not speaker_raw:
        return PiperVoiceSpec(model=model, speaker_id=fallback_speaker_id)

    try:
        speaker_id = int(speaker_raw)
    except ValueError:
        speaker_id = fallback_speaker_id
    return PiperVoiceSpec(model=model, speaker_id=speaker_id)


def _normalize_piece_voice_key(speaker_name: str | None) -> str | None:
    normalized = " ".join((speaker_name or "").split()).strip().lower()
    if normalized in PIPER_PIECE_VOICE_KEYS:
        return normalized
    return None


def _load_wav_as_pcm(path: Path) -> tuple[int, bytes]:
    with wave.open(str(path), "rb") as wav_file:
        sample_rate = wav_file.getframerate()
        sample_width = wav_file.getsampwidth()
        channels = wav_file.getnchannels()
        pcm_bytes = wav_file.readframes(wav_file.getnframes())

    if sample_width != 2:
        raise RuntimeError(f"Unsupported Piper sample width {sample_width * 8}-bit; expected 16-bit PCM.")

    if channels <= 1:
        return sample_rate, pcm_bytes

    samples = array("h")
    samples.frombytes(pcm_bytes)
    mono_samples = array("h")
    for index in range(0, len(samples), channels):
        frame = samples[index : index + channels]
        mono_samples.append(int(sum(frame) / len(frame)))
    return sample_rate, mono_samples.tobytes()


def _iter_pcm_chunks(pcm_bytes: bytes, *, chunk_size_bytes: int) -> list[bytes]:
    return [
        pcm_bytes[offset : offset + chunk_size_bytes]
        for offset in range(0, len(pcm_bytes), max(chunk_size_bytes, 1))
        if pcm_bytes[offset : offset + chunk_size_bytes]
    ]


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
        self._local_piper = PassiveLocalPiperConfig.from_env(self._logger)
        self._local_piper_synthesizer = (
            PassiveLocalPiperSynthesizer(self._local_piper, logger=self._logger)
            if self._local_piper is not None
            else None
        )

    async def run(self) -> None:
        await self._frontend_socket.accept()
        if self._local_piper_synthesizer is not None:
            await self._send_frontend(
                {
                    "type": "status",
                    "state": "ready",
                    "message": "Local Piper passive voices ready.",
                }
            )
        else:
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
            speaker_role = str(payload.get("speaker_role") or "narrator").strip().lower()
            if speaker_role not in {"narrator", "piece"}:
                speaker_role = "narrator"
            speaker_name = " ".join(str(payload.get("speaker_name") or "").split()).strip() or None
            if self._response_in_flight:
                await self._send_frontend({"type": "busy", "message": "Automatic voice audio is already in flight."})
                return
            self._response_in_flight = True
            await self._send_frontend({"type": "streaming", "active": True})
            try:
                if self._local_piper_synthesizer is not None:
                    await self._local_piper_synthesizer.stream_to_frontend(
                        frontend_send=self._send_frontend,
                        text=line,
                        speaker_role=speaker_role,
                        speaker_name=speaker_name,
                    )
                    self._response_in_flight = False
                    await self._send_frontend({"type": "turn_complete", "turn_complete": True})
                    await self._send_frontend({"type": "streaming", "active": False})
                else:
                    await self._send_user_turn(line, speaker_role=speaker_role, speaker_name=speaker_name)
            except Exception as exc:
                self._response_in_flight = False
                await self._send_frontend({"type": "streaming", "active": False})
                await self._send_frontend(
                    {
                        "type": "status",
                        "state": "error",
                        "message": (
                            f"Local passive voice synthesis failed: {exc}"
                            if self._local_piper_synthesizer is not None
                            else f"Gemini passive automatic voice send failed: {exc}"
                        ),
                    }
                )
            return

        if message_type == "ping":
            await self._send_frontend({"type": "pong"})

    async def _send_user_turn(self, line: str, *, speaker_role: str, speaker_name: str | None) -> None:
        if speaker_role == "piece":
            role_instruction = (
                "Speak the following chess piece line aloud exactly as written. "
                "It is already written in first person from inside the battle. "
                "Deliver it with immediate, characterful, reactive energy. "
                "Do not add or change any words.\n"
            )
            if speaker_name:
                role_instruction += f"Speaking piece: {speaker_name}\n"
        else:
            role_instruction = (
                "Speak the following narrator line aloud exactly as written. "
                "Deliver it calm, warm, observant, and cinematic. "
                "Do not add or change any words.\n"
            )
        await self._wait_until_gemini_ready()
        await self._send_gemini_json(
            {
                "clientContent": {
                    "turns": [
                        {
                            "role": "user",
                            "parts": [
                                {
                                    "text": role_instruction + f"Line: {line}"
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
