#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_URL="https://huggingface.co/rhasspy/piper-voices/resolve/main"

download_voice() {
  local target_dir="$1"
  local source_dir="$2"
  local model_name="$3"

  mkdir -p "$target_dir"

  if [[ -f "$target_dir/$model_name.onnx" && -f "$target_dir/$model_name.onnx.json" ]]; then
    echo "Already present: $model_name"
    return
  fi

  echo "Downloading $model_name"
  curl -L --fail --silent --show-error \
    "$BASE_URL/$source_dir/$model_name.onnx" \
    -o "$target_dir/$model_name.onnx"
  curl -L --fail --silent --show-error \
    "$BASE_URL/$source_dir/$model_name.onnx.json" \
    -o "$target_dir/$model_name.onnx.json"
}

download_voice "$ROOT_DIR/piper/voices/audition" "en/en_GB/northern_english_male/medium" "en_GB-northern_english_male-medium"
download_voice "$ROOT_DIR/piper/voices/audition" "en/en_US/joe/medium" "en_US-joe-medium"
download_voice "$ROOT_DIR/piper/voices/knight" "en/en_US/lessac/medium" "en_US-lessac-medium"
download_voice "$ROOT_DIR/piper/voices/audition" "en/en_US/ryan/medium" "en_US-ryan-medium"
download_voice "$ROOT_DIR/piper/voices/audition" "en/en_US/hfc_female/medium" "en_US-hfc_female-medium"
download_voice "$ROOT_DIR/piper/voices/audition" "en/en_GB/alan/medium" "en_GB-alan-medium"

echo "Selected Piper piece voices are ready under $ROOT_DIR/piper/voices"
