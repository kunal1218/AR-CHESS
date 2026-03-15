from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import threading
import time
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from uuid import uuid4

from services.piper_cache import (
    PiperAudioCache,
    build_piper_cache_key,
    normalize_cacheable_tts_text,
    sanitize_cache_filename_component,
)

try:
    from piper.config import SynthesisConfig
    from piper.voice import PiperVoice
except ImportError:  # pragma: no cover - optional runtime fallback
    PiperVoice = None
    SynthesisConfig = None


LOGGER = logging.getLogger("archess.piper.tts")
SERVER_APP_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG_PATH = SERVER_APP_ROOT / "config" / "piper_voices.json"
DEFAULT_CACHE_DIR = SERVER_APP_ROOT / ".cache" / "piper"
DEFAULT_VOICE_SEARCH_ROOT = SERVER_APP_ROOT / "piper" / "voices"
SUPPORTED_PIPER_SPEAKER_TYPES = ("pawn", "rook", "knight", "bishop", "queen", "king", "narrator")


class PiperConfigurationError(RuntimeError):
    """Raised when Piper is configured incorrectly."""


class PiperSynthesisError(RuntimeError):
    """Raised when Piper synthesis fails."""


class PiperAudioNotFoundError(FileNotFoundError):
    """Raised when a cached Piper audio file cannot be found."""


@dataclass(frozen=True)
class PiperVoiceSpec:
    speaker_type: str
    model_path: Path
    config_path: Path
    speaker_id: int | None = None
    preload: bool = False


@dataclass(frozen=True)
class PiperRuntimeConfig:
    binary_path: Path | None
    cache_dir: Path
    default_speaker_type: str
    voices: dict[str, PiperVoiceSpec]


@dataclass(frozen=True)
class PiperResolvedVoice:
    requested_speaker_type: str
    resolved_speaker_type: str
    used_fallback_voice: bool
    spec: PiperVoiceSpec
    voice_signature: str


@dataclass(frozen=True)
class PiperSynthesisResult:
    requested_speaker_type: str
    resolved_speaker_type: str
    cache_key: str
    cache_hit: bool
    used_fallback_voice: bool
    audio_path: Path


@dataclass(frozen=True)
class PiperAvailableVoice:
    voice_id: str
    name: str
    language: str | None
    quality: str | None
    sample_rate: int | None
    model_path: Path
    config_path: Path
    configured_speaker_types: tuple[str, ...]


@dataclass(frozen=True)
class PiperVoiceInventory:
    default_speaker_type: str
    speaker_assignments: dict[str, str | None]
    voices: list[PiperAvailableVoice]


@dataclass(frozen=True)
class PiperAuditionResult:
    voice_id: str
    cache_key: str
    cache_hit: bool
    audio_path: Path


@dataclass
class LoadedPiperVoice:
    signature: str
    voice: PiperVoice
    lock: threading.Lock


class PiperTTSService:
    def __init__(self) -> None:
        self._config_path = self._resolve_config_path(os.getenv("PIPER_VOICES_CONFIG_PATH"))
        self._timeout_seconds = float(os.getenv("PIPER_TTS_TIMEOUT_SECONDS", "20"))
        self._force_subprocess = self._parse_bool_env("PIPER_TTS_FORCE_SUBPROCESS")
        self._config_lock = threading.Lock()
        self._config_mtime_ns: int | None = None
        self._runtime_config: PiperRuntimeConfig | None = None
        self._generation_lock = threading.Lock()
        self._generation_locks: dict[str, threading.Lock] = {}
        self._loaded_voice_lock = threading.Lock()
        self._loaded_voices: dict[str, LoadedPiperVoice] = {}

    def synthesize(self, speaker_type: str, text: str) -> PiperSynthesisResult:
        normalized_speaker_type = self._normalize_speaker_type(speaker_type)
        normalized_text = normalize_cacheable_tts_text(text)
        if not normalized_text:
            raise ValueError("text must not be empty.")

        runtime = self._load_runtime_config()
        resolved_voice = self._resolve_voice(normalized_speaker_type, runtime)
        cached = self._synthesize_cached(
            runtime=runtime,
            requested_cache_label=normalized_speaker_type,
            resolved_cache_label=resolved_voice.resolved_speaker_type,
            voice=resolved_voice.spec,
            text=normalized_text,
            voice_signature=resolved_voice.voice_signature,
        )
        return PiperSynthesisResult(
            requested_speaker_type=normalized_speaker_type,
            resolved_speaker_type=resolved_voice.resolved_speaker_type,
            cache_key=cached.cache_key,
            cache_hit=cached.cache_hit,
            used_fallback_voice=resolved_voice.used_fallback_voice,
            audio_path=cached.audio_path,
        )

    def synthesize_audition(self, voice_id: str, text: str) -> PiperAuditionResult:
        normalized_text = normalize_cacheable_tts_text(text)
        if not normalized_text:
            raise ValueError("text must not be empty.")

        runtime = self._load_runtime_config()
        voice = self._resolve_available_voice(voice_id, runtime)
        cached = self._synthesize_cached(
            runtime=runtime,
            requested_cache_label="audition",
            resolved_cache_label=sanitize_cache_filename_component(voice.voice_id, max_length=24),
            voice=PiperVoiceSpec(
                speaker_type=f"audition:{voice.voice_id}",
                model_path=voice.model_path,
                config_path=voice.config_path,
            ),
            text=normalized_text,
            voice_signature=self._voice_signature(
                PiperVoiceSpec(
                    speaker_type=f"audition:{voice.voice_id}",
                    model_path=voice.model_path,
                    config_path=voice.config_path,
                )
            ),
        )
        return PiperAuditionResult(
            voice_id=voice.voice_id,
            cache_key=cached.cache_key,
            cache_hit=cached.cache_hit,
            audio_path=cached.audio_path,
        )

    def list_available_voices(self) -> PiperVoiceInventory:
        runtime = self._load_runtime_config()
        discovered: dict[str, PiperVoiceSpec] = {}
        speaker_assignments: dict[str, str | None] = {}
        configured_speaker_types_by_voice_id: dict[str, set[str]] = {}

        for speaker_type, voice in runtime.voices.items():
            voice_id = self._voice_id_for_paths(voice.model_path)
            speaker_assignments[speaker_type] = voice_id
            configured_speaker_types_by_voice_id.setdefault(voice_id, set()).add(speaker_type)
            if self._voice_files_exist(voice):
                discovered.setdefault(voice_id, voice)

        for voice_id, voice in self._discover_installed_voices(runtime).items():
            discovered.setdefault(voice_id, voice)

        voices: list[PiperAvailableVoice] = []
        for voice_id, voice in discovered.items():
            metadata = self._read_voice_metadata(voice.config_path)
            voices.append(
                PiperAvailableVoice(
                    voice_id=voice_id,
                    name=voice.model_path.stem,
                    language=self._voice_language(metadata, voice.model_path),
                    quality=self._voice_quality(metadata, voice.model_path),
                    sample_rate=self._voice_sample_rate(metadata),
                    model_path=voice.model_path,
                    config_path=voice.config_path,
                    configured_speaker_types=tuple(sorted(configured_speaker_types_by_voice_id.get(voice_id, set()))),
                )
            )

        voices.sort(key=lambda voice: ((voice.language or "").lower(), voice.name.lower(), voice.voice_id.lower()))
        return PiperVoiceInventory(
            default_speaker_type=runtime.default_speaker_type,
            speaker_assignments=speaker_assignments,
            voices=voices,
        )

    def assign_voice(self, speaker_type: str, voice_id: str) -> PiperVoiceInventory:
        normalized_speaker_type = self._normalize_speaker_type(speaker_type)
        runtime = self._load_runtime_config()
        voice = self._resolve_available_voice(voice_id, runtime)

        with self._config_lock:
            payload = self._read_raw_config_payload()
            voices_payload = payload.get("voices")
            if not isinstance(voices_payload, dict):
                raise PiperConfigurationError("Piper voice config must define a voices map.")

            existing_entry = voices_payload.get(normalized_speaker_type)
            if existing_entry is None:
                existing_entry = {}
            if not isinstance(existing_entry, dict):
                raise PiperConfigurationError(
                    f"Piper voice entry for {normalized_speaker_type} must be an object."
                )

            updated_entry = dict(existing_entry)
            updated_entry["model_path"] = self._path_to_config_value(voice.model_path)
            updated_entry["config_path"] = self._path_to_config_value(voice.config_path)
            updated_entry.pop("speaker_id", None)
            voices_payload[normalized_speaker_type] = updated_entry

            self._write_raw_config_payload(payload)
            self._runtime_config = None
            self._config_mtime_ns = None
            self._loaded_voices.clear()

        LOGGER.info(
            "Assigned Piper voice_id=%s to speaker_type=%s.",
            voice.voice_id,
            normalized_speaker_type,
        )
        return self.list_available_voices()

    def audio_path_for_cache_key(self, cache_key: str) -> Path:
        runtime = self._load_runtime_config()
        cache = PiperAudioCache(runtime.cache_dir)
        audio_path = cache.audio_path(cache_key)
        if not audio_path.is_file() or audio_path.stat().st_size == 0:
            raise PiperAudioNotFoundError(f"Piper audio cache miss for {cache_key}.")
        return audio_path

    def prewarm_configured_voices(self) -> None:
        runtime = self._load_runtime_config()
        if not self._can_use_python_runtime():
            LOGGER.info("Skipping Piper voice prewarm because the in-process runtime is unavailable.")
            return

        speaker_types = {runtime.default_speaker_type}
        for speaker_type, voice in runtime.voices.items():
            if voice.preload:
                speaker_types.add(speaker_type)

        for speaker_type in sorted(speaker_types):
            voice = runtime.voices.get(speaker_type)
            if voice is None or not self._voice_files_exist(voice):
                continue
            try:
                self._get_loaded_voice(voice)
            except Exception as exc:  # pragma: no cover - best effort warmup
                LOGGER.warning("Piper prewarm failed for speaker_type=%s: %s", speaker_type, exc)

    def _load_runtime_config(self) -> PiperRuntimeConfig:
        with self._config_lock:
            if not self._config_path.is_file():
                raise PiperConfigurationError(
                    f"Piper voice config file not found at {self._config_path}."
                )

            mtime_ns = self._config_path.stat().st_mtime_ns
            if self._runtime_config is not None and self._config_mtime_ns == mtime_ns:
                return self._runtime_config

            payload = self._read_raw_config_payload()
            binary_setting = os.getenv("PIPER_BINARY_PATH") or payload.get("binary_path")
            cache_dir = self._resolve_optional_path(os.getenv("PIPER_CACHE_DIR") or payload.get("cache_dir"))
            default_speaker_type = self._normalize_speaker_type(payload.get("default_speaker_type") or "narrator")
            voices_payload = payload.get("voices")
            if not isinstance(voices_payload, dict) or not voices_payload:
                raise PiperConfigurationError("Piper voice config must define a non-empty voices map.")

            voices: dict[str, PiperVoiceSpec] = {}
            for speaker_type, entry in voices_payload.items():
                normalized_speaker_type = self._normalize_speaker_type(speaker_type)
                if not isinstance(entry, dict):
                    raise PiperConfigurationError(f"Piper voice entry for {speaker_type} must be an object.")
                voices[normalized_speaker_type] = self._voice_spec_from_entry(normalized_speaker_type, entry)

            if default_speaker_type not in voices:
                raise PiperConfigurationError(
                    f"Piper default_speaker_type {default_speaker_type!r} is missing from the voices map."
                )

            runtime = PiperRuntimeConfig(
                binary_path=self._resolve_binary_path(
                    binary_setting,
                    required=not self._can_use_python_runtime(),
                ),
                cache_dir=cache_dir or DEFAULT_CACHE_DIR,
                default_speaker_type=default_speaker_type,
                voices=voices,
            )
            self._runtime_config = runtime
            self._config_mtime_ns = mtime_ns
            return runtime

    def _voice_spec_from_entry(self, speaker_type: str, entry: dict[str, object]) -> PiperVoiceSpec:
        model_setting = entry.get("model_path")
        if not isinstance(model_setting, str) or not model_setting.strip():
            raise PiperConfigurationError(f"Piper voice {speaker_type} is missing model_path.")

        model_path = self._resolve_required_path(model_setting)
        config_setting = entry.get("config_path")
        if config_setting is None:
            config_path = Path(f"{model_path}.json")
        else:
            if not isinstance(config_setting, str) or not config_setting.strip():
                raise PiperConfigurationError(f"Piper voice {speaker_type} has an invalid config_path.")
            config_path = self._resolve_required_path(config_setting)

        speaker_id = entry.get("speaker_id")
        if speaker_id is not None:
            try:
                speaker_id = int(speaker_id)
            except (TypeError, ValueError) as exc:
                raise PiperConfigurationError(f"Piper voice {speaker_type} has an invalid speaker_id.") from exc

        preload = entry.get("preload", False)
        if not isinstance(preload, bool):
            raise PiperConfigurationError(f"Piper voice {speaker_type} has an invalid preload flag.")

        return PiperVoiceSpec(
            speaker_type=speaker_type,
            model_path=model_path,
            config_path=config_path,
            speaker_id=speaker_id,
            preload=preload,
        )

    def _resolve_voice(self, requested_speaker_type: str, runtime: PiperRuntimeConfig) -> PiperResolvedVoice:
        requested_voice = runtime.voices.get(requested_speaker_type)
        if requested_voice is not None and self._voice_files_exist(requested_voice):
            return PiperResolvedVoice(
                requested_speaker_type=requested_speaker_type,
                resolved_speaker_type=requested_speaker_type,
                used_fallback_voice=False,
                spec=requested_voice,
                voice_signature=self._voice_signature(requested_voice),
            )

        default_voice = runtime.voices.get(runtime.default_speaker_type)
        if requested_voice is None:
            LOGGER.warning(
                "Piper voice map is missing speaker_type=%s. Falling back to %s.",
                requested_speaker_type,
                runtime.default_speaker_type,
            )
        else:
            LOGGER.warning(
                "Piper voice files missing for speaker_type=%s model=%s config=%s. Falling back to %s.",
                requested_speaker_type,
                requested_voice.model_path,
                requested_voice.config_path,
                runtime.default_speaker_type,
            )

        if default_voice is None or not self._voice_files_exist(default_voice):
            raise PiperConfigurationError(
                f"Piper fallback voice {runtime.default_speaker_type!r} is unavailable."
            )

        return PiperResolvedVoice(
            requested_speaker_type=requested_speaker_type,
            resolved_speaker_type=runtime.default_speaker_type,
            used_fallback_voice=requested_speaker_type != runtime.default_speaker_type,
            spec=default_voice,
            voice_signature=self._voice_signature(default_voice),
        )

    def _synthesize_cached(
        self,
        *,
        runtime: PiperRuntimeConfig,
        requested_cache_label: str,
        resolved_cache_label: str,
        voice: PiperVoiceSpec,
        text: str,
        voice_signature: str,
    ) -> PiperAuditionResult:
        cache = PiperAudioCache(runtime.cache_dir)
        cache_key = build_piper_cache_key(
            requested_speaker_type=requested_cache_label,
            resolved_speaker_type=resolved_cache_label,
            text=text,
            voice_signature=voice_signature,
        )
        audio_path = cache.audio_path(cache_key)

        if cache.has_audio(cache_key):
            return PiperAuditionResult(
                voice_id=voice.speaker_type,
                cache_key=cache_key,
                cache_hit=True,
                audio_path=audio_path,
            )

        generation_lock = self._lock_for_cache_key(cache_key)
        with generation_lock:
            if cache.has_audio(cache_key):
                return PiperAuditionResult(
                    voice_id=voice.speaker_type,
                    cache_key=cache_key,
                    cache_hit=True,
                    audio_path=audio_path,
                )

            self._synthesize_to_file(runtime, voice, text, audio_path)

        return PiperAuditionResult(
            voice_id=voice.speaker_type,
            cache_key=cache_key,
            cache_hit=False,
            audio_path=audio_path,
        )

    def _resolve_available_voice(self, raw_voice_id: str, runtime: PiperRuntimeConfig) -> PiperAvailableVoice:
        voice_id = normalize_cacheable_tts_text(raw_voice_id)
        if not voice_id:
            raise ValueError("voice_id must not be empty.")

        inventory = self.list_available_voices()
        for voice in inventory.voices:
            if voice.voice_id == voice_id:
                return voice

        raise PiperConfigurationError(f"Piper voice_id {voice_id!r} is not installed.")

    def _discover_installed_voices(self, runtime: PiperRuntimeConfig) -> dict[str, PiperVoiceSpec]:
        discovered: dict[str, PiperVoiceSpec] = {}
        search_roots = {DEFAULT_VOICE_SEARCH_ROOT}
        for voice in runtime.voices.values():
            search_roots.add(voice.model_path.parent)

        for root in search_roots:
            if not root.is_dir():
                continue
            for model_path in sorted(root.rglob("*.onnx")):
                config_path = Path(f"{model_path}.json")
                if not config_path.is_file():
                    continue
                voice_id = self._voice_id_for_paths(model_path)
                discovered.setdefault(
                    voice_id,
                    PiperVoiceSpec(
                        speaker_type=f"voice:{voice_id}",
                        model_path=model_path.resolve(),
                        config_path=config_path.resolve(),
                    ),
                )
        return discovered

    def _read_voice_metadata(self, config_path: Path) -> dict[str, Any]:
        try:
            with config_path.open("r", encoding="utf-8") as handle:
                payload = json.load(handle)
        except (OSError, json.JSONDecodeError):
            return {}
        return payload if isinstance(payload, dict) else {}

    def _voice_language(self, metadata: dict[str, Any], model_path: Path) -> str | None:
        espeak = metadata.get("espeak")
        if isinstance(espeak, dict):
            voice = espeak.get("voice")
            if isinstance(voice, str) and voice.strip():
                return voice.strip()

        stem = model_path.stem
        if "-" in stem:
            return stem.split("-", 1)[0].replace("_", "-")
        return None

    def _voice_quality(self, metadata: dict[str, Any], model_path: Path) -> str | None:
        audio = metadata.get("audio")
        if isinstance(audio, dict):
            quality = audio.get("quality")
            if isinstance(quality, str) and quality.strip():
                return quality.strip()

        lowered_stem = model_path.stem.lower()
        for quality in ("x_low", "low", "medium", "high"):
            if lowered_stem.endswith(f"-{quality}") or lowered_stem.endswith(f"_{quality}"):
                return quality.replace("_", "-")
        return None

    def _voice_sample_rate(self, metadata: dict[str, Any]) -> int | None:
        audio = metadata.get("audio")
        if not isinstance(audio, dict):
            return None
        sample_rate = audio.get("sample_rate")
        return sample_rate if isinstance(sample_rate, int) and sample_rate > 0 else None

    def _voice_id_for_paths(self, model_path: Path) -> str:
        resolved_path = model_path.resolve()
        for base_path in (DEFAULT_VOICE_SEARCH_ROOT, SERVER_APP_ROOT):
            try:
                return resolved_path.relative_to(base_path.resolve()).with_suffix("").as_posix()
            except ValueError:
                continue
        return resolved_path.with_suffix("").name

    def _synthesize_to_file(
        self,
        runtime: PiperRuntimeConfig,
        voice: PiperVoiceSpec,
        text: str,
        output_path: Path,
    ) -> None:
        if self._can_use_python_runtime():
            try:
                self._synthesize_with_loaded_voice(voice, text, output_path)
                return
            except Exception as exc:
                if runtime.binary_path is None:
                    if isinstance(exc, PiperSynthesisError):
                        raise
                    raise PiperSynthesisError(f"Piper runtime synthesis failed: {exc}") from exc
                LOGGER.warning(
                    "Piper in-process synthesis failed for voice=%s. Falling back to subprocess. error=%s",
                    voice.speaker_type,
                    exc,
                )

        if runtime.binary_path is None:
            raise PiperConfigurationError(
                "Piper is unavailable because neither the Python runtime nor a Piper binary is configured."
            )
        self._run_piper(runtime, voice, text, output_path)

    def _synthesize_with_loaded_voice(self, voice: PiperVoiceSpec, text: str, output_path: Path) -> None:
        loaded_voice = self._get_loaded_voice(voice)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        temp_output_path = output_path.with_name(f"{output_path.stem}-{uuid4().hex}.tmp.wav")
        temp_output_path.unlink(missing_ok=True)
        synthesis_config = self._build_synthesis_config(voice)
        started_at = time.perf_counter()

        try:
            with loaded_voice.lock:
                with wave.open(str(temp_output_path), "wb") as wav_file:
                    loaded_voice.voice.synthesize_wav(
                        text,
                        wav_file,
                        syn_config=synthesis_config,
                        set_wav_format=True,
                    )
        except Exception as exc:
            temp_output_path.unlink(missing_ok=True)
            raise PiperSynthesisError(
                f"Piper runtime synthesis failed for voice={voice.speaker_type}: {exc}"
            ) from exc

        if not temp_output_path.is_file() or temp_output_path.stat().st_size == 0:
            temp_output_path.unlink(missing_ok=True)
            raise PiperSynthesisError("Piper runtime did not produce a non-empty wav file.")

        temp_output_path.replace(output_path)
        LOGGER.info(
            "Piper synthesized voice=%s via in-process runtime in %.1fms.",
            voice.speaker_type,
            (time.perf_counter() - started_at) * 1000,
        )

    def _get_loaded_voice(self, voice: PiperVoiceSpec) -> LoadedPiperVoice:
        if not self._can_use_python_runtime() or PiperVoice is None:
            raise PiperConfigurationError("Piper Python runtime is unavailable.")

        signature = self._voice_signature(voice)
        with self._loaded_voice_lock:
            existing = self._loaded_voices.get(signature)
            if existing is not None:
                return existing

            started_at = time.perf_counter()
            try:
                loaded_voice = PiperVoice.load(voice.model_path, config_path=voice.config_path)
            except Exception as exc:
                raise PiperSynthesisError(f"Piper runtime could not load voice={voice.speaker_type}: {exc}") from exc

            wrapped = LoadedPiperVoice(
                signature=signature,
                voice=loaded_voice,
                lock=threading.Lock(),
            )
            self._loaded_voices[signature] = wrapped
            LOGGER.info(
                "Loaded Piper voice=%s in %.1fms.",
                voice.speaker_type,
                (time.perf_counter() - started_at) * 1000,
            )
            return wrapped

    def _build_synthesis_config(self, voice: PiperVoiceSpec) -> SynthesisConfig | None:
        if voice.speaker_id is None or SynthesisConfig is None:
            return None
        return SynthesisConfig(speaker_id=voice.speaker_id)

    def _run_piper(self, runtime: PiperRuntimeConfig, voice: PiperVoiceSpec, text: str, output_path: Path) -> None:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        temp_output_path = output_path.with_name(f"{output_path.stem}-{uuid4().hex}.tmp.wav")
        temp_output_path.unlink(missing_ok=True)

        command = [
            str(runtime.binary_path),
            "--model",
            str(voice.model_path),
            "--config",
            str(voice.config_path),
            "--output_file",
            str(temp_output_path),
        ]
        if voice.speaker_id is not None:
            command.extend(["--speaker", str(voice.speaker_id)])

        started_at = time.perf_counter()
        try:
            completed = subprocess.run(
                command,
                input=text,
                capture_output=True,
                text=True,
                check=False,
                timeout=self._timeout_seconds,
            )
        except FileNotFoundError as exc:
            raise PiperConfigurationError(f"Piper binary not found at {runtime.binary_path}.") from exc
        except subprocess.TimeoutExpired as exc:
            temp_output_path.unlink(missing_ok=True)
            raise PiperSynthesisError(f"Piper timed out after {self._timeout_seconds:.1f}s.") from exc
        except OSError as exc:
            temp_output_path.unlink(missing_ok=True)
            raise PiperSynthesisError(f"Could not launch Piper: {exc}") from exc

        stderr = completed.stderr.strip()
        stdout = completed.stdout.strip()
        if completed.returncode != 0:
            temp_output_path.unlink(missing_ok=True)
            details = stderr or stdout or f"exit code {completed.returncode}"
            raise PiperSynthesisError(f"Piper exited unsuccessfully: {details}")

        if not temp_output_path.is_file() or temp_output_path.stat().st_size == 0:
            temp_output_path.unlink(missing_ok=True)
            raise PiperSynthesisError("Piper did not produce a non-empty wav file.")

        temp_output_path.replace(output_path)
        LOGGER.info(
            "Piper synthesized voice=%s via subprocess in %.1fms.",
            voice.speaker_type,
            (time.perf_counter() - started_at) * 1000,
        )

    def _voice_files_exist(self, voice: PiperVoiceSpec) -> bool:
        return voice.model_path.is_file() and voice.config_path.is_file()

    def _voice_signature(self, voice: PiperVoiceSpec) -> str:
        model_mtime = voice.model_path.stat().st_mtime_ns if voice.model_path.exists() else 0
        config_mtime = voice.config_path.stat().st_mtime_ns if voice.config_path.exists() else 0
        speaker_id = voice.speaker_id if voice.speaker_id is not None else ""
        return "|".join(
            [
                str(voice.model_path.resolve()),
                str(model_mtime),
                str(voice.config_path.resolve()),
                str(config_mtime),
                str(speaker_id),
            ]
        )

    def _lock_for_cache_key(self, cache_key: str) -> threading.Lock:
        with self._generation_lock:
            existing = self._generation_locks.get(cache_key)
            if existing is not None:
                return existing
            created = threading.Lock()
            self._generation_locks[cache_key] = created
            return created

    def _resolve_config_path(self, raw_path: str | None) -> Path:
        if raw_path and raw_path.strip():
            return self._resolve_required_path(raw_path)
        return DEFAULT_CONFIG_PATH

    def _resolve_binary_path(self, raw_value: object, *, required: bool) -> Path | None:
        if not isinstance(raw_value, str) or not raw_value.strip():
            if required:
                raise PiperConfigurationError("Piper binary_path must be configured.")
            return None

        trimmed = raw_value.strip()
        if "/" not in trimmed and "\\" not in trimmed and not trimmed.startswith("."):
            resolved = shutil.which(trimmed)
            if resolved:
                return Path(resolved).resolve()

        candidate = self._resolve_required_path(trimmed)
        if candidate.is_file():
            return candidate
        if required:
            raise PiperConfigurationError(f"Piper binary not found at {candidate}.")

        LOGGER.warning(
            "Configured Piper binary_path=%s was not found. Using the in-process Piper runtime instead.",
            trimmed,
        )
        return None

    def _resolve_optional_path(self, raw_value: object) -> Path | None:
        if raw_value is None:
            return None
        if not isinstance(raw_value, str) or not raw_value.strip():
            raise PiperConfigurationError("Piper path settings must be non-empty strings.")
        return self._resolve_required_path(raw_value)

    def _resolve_required_path(self, raw_value: str) -> Path:
        candidate = Path(raw_value.strip())
        if candidate.is_absolute():
            return candidate
        return (SERVER_APP_ROOT / candidate).resolve()

    def _normalize_speaker_type(self, value: object) -> str:
        if not isinstance(value, str):
            raise PiperConfigurationError("Piper speaker_type values must be strings.")
        normalized = value.strip().lower()
        if normalized not in SUPPORTED_PIPER_SPEAKER_TYPES:
            raise PiperConfigurationError(
                "Piper speaker_type must be one of pawn, rook, knight, bishop, queen, king, narrator."
            )
        return normalized

    def _path_to_config_value(self, path: Path) -> str:
        resolved_path = path.resolve()
        try:
            return resolved_path.relative_to(SERVER_APP_ROOT).as_posix()
        except ValueError:
            return str(resolved_path)

    def _read_raw_config_payload(self) -> dict[str, Any]:
        with self._config_path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
        if not isinstance(payload, dict):
            raise PiperConfigurationError("Piper voice config must be a JSON object.")
        return payload

    def _write_raw_config_payload(self, payload: dict[str, Any]) -> None:
        self._config_path.parent.mkdir(parents=True, exist_ok=True)
        temp_path = self._config_path.with_name(f"{self._config_path.name}.{uuid4().hex}.tmp")
        with temp_path.open("w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2)
            handle.write("\n")
        temp_path.replace(self._config_path)

    def _can_use_python_runtime(self) -> bool:
        return PiperVoice is not None and not self._force_subprocess

    def _parse_bool_env(self, env_name: str) -> bool:
        raw_value = os.getenv(env_name, "").strip().lower()
        return raw_value in {"1", "true", "yes", "on"}
