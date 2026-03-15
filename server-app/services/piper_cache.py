import hashlib
import re
from pathlib import Path


CACHE_KEY_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{10,127}$")


def normalize_cacheable_tts_text(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def sanitize_cache_filename_component(value: str, *, max_length: int = 48) -> str:
    normalized = normalize_cacheable_tts_text(value).lower()
    sanitized = re.sub(r"[^a-z0-9]+", "-", normalized).strip("-")
    if not sanitized:
        return "line"
    sanitized = sanitized[:max_length].strip("-")
    return sanitized or "line"


def build_piper_cache_key(
    *,
    requested_speaker_type: str,
    resolved_speaker_type: str,
    text: str,
    voice_signature: str,
) -> str:
    normalized_text = normalize_cacheable_tts_text(text)
    seed = "\n".join(
        [
            requested_speaker_type.strip().lower(),
            resolved_speaker_type.strip().lower(),
            voice_signature,
            normalized_text,
        ]
    )
    digest = hashlib.sha256(seed.encode("utf-8")).hexdigest()[:32]
    text_prefix = sanitize_cache_filename_component(normalized_text)
    return f"{requested_speaker_type}-{resolved_speaker_type}-{text_prefix}-{digest}"


def validate_cache_key(cache_key: str) -> str:
    normalized = cache_key.strip().lower()
    if not CACHE_KEY_PATTERN.fullmatch(normalized):
        raise ValueError("cache_key must be a sanitized Piper cache key.")
    return normalized


class PiperAudioCache:
    def __init__(self, cache_dir: Path) -> None:
        self.cache_dir = cache_dir
        self.cache_dir.mkdir(parents=True, exist_ok=True)

    def audio_path(self, cache_key: str) -> Path:
        normalized_key = validate_cache_key(cache_key)
        return self.cache_dir / f"{normalized_key}.wav"

    def has_audio(self, cache_key: str) -> bool:
        path = self.audio_path(cache_key)
        return path.is_file() and path.stat().st_size > 0
