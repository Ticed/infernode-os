#!/usr/bin/env bash
#
# transcribe-pcm.sh — turn a raw PCM recording back into text with the
# same local STT helper the voice stack uses.
#
#   tools/transcribe-pcm.sh <file.pcm> [rate]
#
# Reads 16-bit little-endian mono PCM and prints the transcript. Used to
# check that what a test heard on the audio device is what the screen
# said would be spoken — the audio equivalent of reading the window.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PARAKEET_MANIFEST=${PARAKEET_MANIFEST:-"$SCRIPT_DIR/parakeet-eou.manifest"}
# shellcheck source=parakeet-eou.manifest
source "$PARAKEET_MANIFEST"

file=${1:?usage: transcribe-pcm.sh <file.pcm> [rate]}
rate=${2:-16000}
HELPERS=${INFERNODE_SPEECH_HOME:-$HOME/.local/share/infernode-speech}
BIN=${PARAKEET_STREAM_BIN:-$HELPERS/bin/parakeet-stream}
MODEL=${PARAKEET_MODEL:-$HELPERS/models/parakeet/$PARAKEET_GGUF_FILE}

[ -x "$BIN" ] || { echo "transcribe-pcm: no STT helper at $BIN" >&2; exit 77; }
[ -f "$MODEL" ] || { echo "transcribe-pcm: no model at $MODEL" >&2; exit 77; }

"$BIN" --stdin --model "$MODEL" --rate "$rate" --chans 1 --final-silence-ms 800 \
	<"$file" 2>/dev/null |
	sed -n 's/^final //p' |
	sed 's/^confidence=[0-9.]* //'
