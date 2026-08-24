#!/usr/bin/env bash
#
# virtual-mic.sh — speak into InferNode without speaking.
#
# Plays an audio file into a loopback audio device, so any InferNode
# started with INFERNODE_AUDIO_IN set to that device hears the file as if
# someone had said it into a microphone. The audio crosses the real
# device path; only the microphone and the room are gone.
#
#   # one terminal: the thing under test, listening to the virtual device
#   export INFERNODE_AUDIO_IN=$(tools/virtual-mic.sh --device)
#   export INFERNODE_AUDIO_OUT=$INFERNODE_AUDIO_IN     # keeps replies silent
#   tools/speech-test.sh -w -d
#
#   # another terminal: say something to it
#   tools/virtual-mic.sh tests/fixtures/speech/elevenlabs/voice_submit.pcm
#
# Accepts raw 16 kHz mono signed 16-bit little-endian PCM (.pcm/.raw, the
# format of the committed fixtures) or any file afconvert can read
# (.wav, .m4a, .aiff), which is converted to that format first.
#
#   --device   print the device name and exit
#   --list     print every audio device InferNode can see and exit
#   --rate N   sample rate of a raw PCM file (default 16000)
#
# Pin the device with INFERNODE_VIRTUAL_AUDIO_DEVICE='<name>'. See
# docs/SPEECH-VIRTUAL-AUDIO.md.
set -euo pipefail

ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
cd "$ROOT"
export ROOT

. "$ROOT/tools/virtual-audio.sh"

EMU=$(va_emu)
[ -x "$EMU" ] || { echo "error: emulator not built: $EMU" >&2; exit 1; }

rate=16000
file=
while [ $# -gt 0 ]; do
	case "$1" in
	--device) va_find_device || { echo "error: no virtual loopback audio device — $VA_INSTALL_HINT" >&2; exit 1; }; exit 0 ;;
	--list)   va_enumerate; exit 0 ;;
	--rate)   rate=$2; shift 2 ;;
	-h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	-*)       echo "error: unknown option $1 (see -h)" >&2; exit 2 ;;
	*)        file=$1; shift ;;
	esac
done

[ -n "$file" ] || { echo "usage: tools/virtual-mic.sh [--rate N] <audio-file>" >&2; exit 2; }
[ -s "$file" ] || { echo "error: no such audio file: $file" >&2; exit 1; }

device=$(va_find_device) ||
	{ echo "error: no virtual loopback audio device — $VA_INSTALL_HINT" >&2; exit 1; }

# The emulator can only read inside its own -r tree, so a file from
# anywhere else is staged into it rather than played in place.
staged=
case "$file" in
*.pcm|*.raw)
	case "$file" in
	/*) ;;
	*)  file=$(cd "$(dirname "$file")" && pwd)/$(basename "$file") ;;
	esac
	case "$file" in
	"$ROOT"/*) play=${file#"$ROOT"} ;;
	*)  mkdir -p "$ROOT/.omx/tmp"
	    staged=$(mktemp "$ROOT/.omx/tmp/virtual-mic.XXXXXX.pcm")
	    cp "$file" "$staged"
	    play=${staged#"$ROOT"} ;;
	esac
	;;
*)
	command -v afconvert >/dev/null 2>&1 ||
		{ echo "error: cannot convert $file without afconvert (macOS)" >&2; exit 1; }
	mkdir -p "$ROOT/.omx/tmp"
	staged=$(mktemp "$ROOT/.omx/tmp/virtual-mic.XXXXXX.pcm")
	afconvert -f caff -d LEI16@16000 -c 1 "$file" "$staged.caf" >/dev/null
	# Strip the container: /dev/audio takes samples, not a header.
	afconvert -f 'data' -d LEI16@16000 -c 1 "$staged.caf" "$staged" >/dev/null
	rm -f "$staged.caf"
	rate=16000
	play=${staged#"$ROOT"}
	;;
esac
trap '[ -n "$staged" ] && rm -f "$staged"' EXIT

echo "virtual-mic: playing $file into '$device' at ${rate} Hz mono"
INFERNODE_AUDIO_OUT=$device "$EMU" -r. /dis/sh.dis -c "
	bind -a '#A' /dev
	echo 'out rate $rate chans 1 bits 16 enc pcm' > /dev/audioctl
	cat /$play > /dev/audio
"
