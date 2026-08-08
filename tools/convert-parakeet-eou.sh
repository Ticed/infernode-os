#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MANIFEST=${PARAKEET_MANIFEST:-"$SCRIPT_DIR/parakeet-eou.manifest"}
# shellcheck source=parakeet-eou.manifest
source "$MANIFEST"

WORK=${PARAKEET_CONVERT_WORK:-"${XDG_CACHE_HOME:-$HOME/.cache}/infernode-speech/parakeet-convert"}
OUTPUT=${PARAKEET_CONVERT_OUTPUT:-"$PWD/$PARAKEET_GGUF_FILE"}
SOURCE_MODEL=${PARAKEET_SOURCE_MODEL:-"$WORK/$PARAKEET_MODEL_FILE"}
CONVERTER=${PARAKEET_CONVERTER:-}
PYTHON=${PARAKEET_CONVERT_PYTHON:-}
BOOTSTRAP_PYTHON=${PARAKEET_CONVERT_BOOTSTRAP_PYTHON:-python3.10}
REQUIREMENTS=${PARAKEET_CONVERT_REQUIREMENTS:-"$SCRIPT_DIR/parakeet-convert-requirements.txt"}

usage() {
  echo "usage: tools/convert-parakeet-eou.sh [--output FILE] [--work DIR] [--verify FILE]" >&2
  exit 2
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

verify_file() {
  local path=$1 expected_sha=$2 expected_size=$3 label=$4
  [ -f "$path" ] || { echo "error: missing $label: $path" >&2; return 1; }
  local actual_size actual_sha
  actual_size=$(wc -c <"$path" | tr -d ' ')
  [ "$actual_size" = "$expected_size" ] || {
    echo "error: $label size mismatch: expected $expected_size, got $actual_size" >&2
    return 1
  }
  actual_sha=$(sha256_file "$path")
  [ "$actual_sha" = "$expected_sha" ] || {
    echo "error: $label SHA-256 mismatch: expected $expected_sha, got $actual_sha" >&2
    return 1
  }
}

verify_only=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) [ "$#" -ge 2 ] || usage; OUTPUT=$2; shift 2 ;;
    --work) [ "$#" -ge 2 ] || usage; WORK=$2; shift 2 ;;
    --verify) [ "$#" -ge 2 ] || usage; verify_only=$2; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

if [ -n "$verify_only" ]; then
  verify_file "$verify_only" "$PARAKEET_GGUF_SHA256" "$PARAKEET_GGUF_SIZE" "Parakeet GGUF"
  echo "verified: $verify_only"
  exit 0
fi

mkdir -p "$WORK" "$(dirname "$OUTPUT")"

if [ ! -f "$SOURCE_MODEL" ]; then
  url="https://huggingface.co/$PARAKEET_MODEL_REPO/resolve/$PARAKEET_MODEL_REVISION/$PARAKEET_MODEL_FILE"
  tmp="$SOURCE_MODEL.tmp"
  echo "download: pinned NVIDIA checkpoint $PARAKEET_MODEL_REVISION"
  curl -L --fail --retry 3 --retry-all-errors --output "$tmp" "$url"
  verify_file "$tmp" "$PARAKEET_MODEL_SHA256" "$PARAKEET_MODEL_SIZE" "NVIDIA checkpoint"
  mv "$tmp" "$SOURCE_MODEL"
fi
verify_file "$SOURCE_MODEL" "$PARAKEET_MODEL_SHA256" "$PARAKEET_MODEL_SIZE" "NVIDIA checkpoint"

if [ -z "$CONVERTER" ]; then
  src="$WORK/parakeet.cpp"
  if [ ! -d "$src/.git" ]; then
    git clone --filter=blob:none --no-checkout "$PARAKEET_CPP_REPO_URL" "$src"
  fi
  git -C "$src" fetch --depth 1 origin "$PARAKEET_CPP_COMMIT"
  git -C "$src" checkout --detach "$PARAKEET_CPP_COMMIT"
  git -C "$src" submodule update --init --recursive --depth 1
  CONVERTER="$src/scripts/convert_parakeet_to_gguf.py"
  if [ -z "$PYTHON" ]; then
    PYTHON="$WORK/venv/bin/python"
    if [ ! -x "$PYTHON" ]; then
      command -v "$BOOTSTRAP_PYTHON" >/dev/null 2>&1 || {
        echo "error: conversion requires CPython 3.10 (set PARAKEET_CONVERT_BOOTSTRAP_PYTHON)" >&2
        exit 1
      }
      case "$($BOOTSTRAP_PYTHON -c 'import sys; print("%d.%d" % sys.version_info[:2])')" in
        3.10) ;;
        *) echo "error: conversion requires CPython 3.10" >&2; exit 1 ;;
      esac
      "$BOOTSTRAP_PYTHON" -m venv "$WORK/venv"
      if [ "$(uname -s)" = Linux ]; then
        "$WORK/venv/bin/pip" install --extra-index-url https://download.pytorch.org/whl/cpu \
          'torch==2.7.1+cpu' -r "$REQUIREMENTS"
      else
        "$WORK/venv/bin/pip" install 'torch==2.7.1' -r "$REQUIREMENTS"
      fi
    fi
  fi
fi

[ -n "$PYTHON" ] || PYTHON=python3
tmp="$OUTPUT.tmp"
find "$tmp" -maxdepth 0 -type f -delete 2>/dev/null || true
"$PYTHON" "$CONVERTER" \
  --model "$SOURCE_MODEL" \
  --dtype "$PARAKEET_GGUF_DTYPE" \
  --output "$tmp"
verify_file "$tmp" "$PARAKEET_GGUF_SHA256" "$PARAKEET_GGUF_SIZE" "converted Parakeet GGUF"
mv "$tmp" "$OUTPUT"
echo "wrote: $OUTPUT"
echo "sha256: $PARAKEET_GGUF_SHA256"
