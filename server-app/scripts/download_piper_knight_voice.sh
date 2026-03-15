#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VOICE_DIR="$ROOT_DIR/piper/voices/knight"
MODEL_NAME="en_US-lessac-high"
BASE_URL="https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/high"

mkdir -p "$VOICE_DIR"

curl -L "$BASE_URL/$MODEL_NAME.onnx.json" -o "$VOICE_DIR/$MODEL_NAME.onnx.json"
curl -L "$BASE_URL/$MODEL_NAME.onnx" -o "$VOICE_DIR/$MODEL_NAME.onnx"

echo "Knight voice downloaded to $VOICE_DIR"
