#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VOICE_DIR="$ROOT_DIR/piper/voices/audition"
VOICE_LIST_PATH="${1:-$ROOT_DIR/config/piper_audition_voices.txt}"
BASE_URL="https://huggingface.co/rhasspy/piper-voices/resolve/main"

if [[ ! -f "$VOICE_LIST_PATH" ]]; then
  echo "Voice list not found: $VOICE_LIST_PATH" >&2
  exit 1
fi

mkdir -p "$VOICE_DIR"

download_voice() {
  local entry="$1"
  local model_stem="${entry##*/}"
  local source_dir="${entry%/*}"

  echo "Downloading $model_stem"
  curl -L --fail --silent --show-error \
    "$BASE_URL/$source_dir/$model_stem.onnx" \
    -o "$VOICE_DIR/$model_stem.onnx"
  curl -L --fail --silent --show-error \
    "$BASE_URL/$source_dir/$model_stem.onnx.json" \
    -o "$VOICE_DIR/$model_stem.onnx.json"
}

while IFS= read -r raw_line; do
  entry="$(echo "$raw_line" | sed 's/#.*$//' | xargs)"
  if [[ -z "$entry" ]]; then
    continue
  fi
  download_voice "$entry"
done < "$VOICE_LIST_PATH"

echo "Downloaded audition voices into $VOICE_DIR"
