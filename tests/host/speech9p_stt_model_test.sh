#!/bin/sh
#
# macOS ENGINE_CMD STT must refuse before opening capture when the
# hardcoded whisper model is missing. brew whisper-cpp does not ship one.
#
# Skip when the model is present: the unfixed path would record from the
# default capture device.
#
# Run from project root: ./tests/host/speech9p_stt_model_test.sh

. "$(dirname "$0")/common.sh"

case "$(uname -s)" in
Darwin) ;;
*) echo "SKIP: macOS STT path only"; exit 77 ;;
esac

MODEL=/opt/homebrew/share/whisper-cpp/models/ggml-base.en.bin
if [ -f "$MODEL" ]; then
	echo "SKIP: $MODEL exists; this test would open capture"
	exit 77
fi

if [ ! -x "$EMU" ]; then
	echo "SKIP: emulator not found at $EMU"
	exit 77
fi
if [ ! -f "$ROOT/dis/sh.dis" ] || [ ! -f "$ROOT/dis/veltro/speech9p.dis" ]; then
	echo "SKIP: Dis runtime not built"
	exit 77
fi

HOME=$(mktemp -d "${TMPDIR:-/tmp}/infernode-stt-model.XXXXXX")
LOG=$(mktemp "${TMPDIR:-/tmp}/infernode-stt-model.log.XXXXXX")
trap 'rm -rf "$HOME" "$LOG"' EXIT

SDL_VIDEODRIVER=dummy
SDL_AUDIODRIVER=dummy
export HOME SDL_VIDEODRIVER SDL_AUDIODRIVER

# Profile starts speech9p -e cmd. Reading hear on a new fid runs STT.
timeout 15 "$EMU" -c0 -r"$ROOT" /dis/sh.dis -l -c \
	'echo HEAR_BEGIN; cat /n/speech/hear; echo HEAR_END' \
	</dev/null >"$LOG" 2>&1 || true

if ! grep -q 'whisper model not found' "$LOG"; then
	echo 'FAIL: missing whisper model was not named'
	echo '--- log ---'
	cat "$LOG"
	exit 1
fi
if grep -qi 'avfoundation\|ffmpeg' "$LOG"; then
	echo 'FAIL: STT invoked capture before checking the model'
	echo '--- log ---'
	cat "$LOG"
	exit 1
fi

echo 'speech9p_stt_model: PASS'
exit 0
