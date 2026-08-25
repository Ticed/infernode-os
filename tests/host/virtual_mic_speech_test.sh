#!/usr/bin/env bash
#
# A microphone that says what the test tells it to say.
#
# One emulator runs the speech stack with its capture pointed at a
# loopback audio device; a second emulator plays a committed speech
# fixture into that same device's output. Nothing is spoken and nothing
# is heard: the audio goes driver-to-driver, but every layer above the
# transducers is real — SDL3, /dev/audio, speechshim9p, speech9p, the
# listen helper, and the turn gate that decides when a turn has ended.
#
# What this covers that nothing else could:
#
#   - the capture path itself. tests/host/elevenlabs_speech_e2e_test.py
#     feeds the same fixtures to the listen helper over stdin, which
#     proves the model and the gate but bypasses the device entirely.
#   - a turn committing from live audio. A file ends; a device does not,
#     so a final here can only have come from the silence gate.
#   - repeatability. The room, the capture gain, and whoever is talking
#     nearby stop being inputs to the result.
#
# Set up the device with tools/virtual-audio.sh; see
# docs/SPEECH-VIRTUAL-AUDIO.md.
set -euo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
cd "$ROOT"
export ROOT
export PATH="$ROOT/MacOSX/arm64/bin:$PATH"

. "$ROOT/tools/virtual-audio.sh"

EMU=$(va_emu)
HELPERS=${INFERNODE_SPEECH_HOME:-$HOME/.local/share/infernode-speech}
TMP=${AUDIO_TEST_TMPDIR:-.omx/tmp}
mkdir -p "$TMP"
log="$TMP/virtual-mic-speech.log"
playlog="$TMP/virtual-mic-play.log"

FIXTURE=${VIRTUAL_MIC_FIXTURE:-voice_submit}
FIXTUREDIR=tests/fixtures/speech/elevenlabs
RATE=16000
READY_TIMEOUT=90        # the listen helper loads a model on first start
FINAL_TIMEOUT=25        # after playback ends, how long a turn may take to commit
MIN_KEYWORDS=2

fail() { echo "FAIL: $1"; exit 1; }
skip() { echo "SKIP: $1"; exit 77; }

listener=
cleanup() {
	[ -n "$listener" ] && kill "$listener" 2>/dev/null || true
	pkill -f "o.emu.*speechtest.dis" 2>/dev/null || true
}
trap cleanup EXIT

[ -d "$HELPERS/bin" ] ||
	skip "no speech helpers installed — run tools/install-speech-helpers.sh"
[ -s "$FIXTUREDIR/$FIXTURE.pcm" ] ||
	fail "missing fixture $FIXTUREDIR/$FIXTURE.pcm"

device=$(va_require_device) || exit $?
echo "virtual audio device: $device"

# Both directions are pinned. Pinning only the input would leave the
# stack's spoken reply on whatever the host's default output happens to
# be, which on a developer machine means the test talks out loud.
export INFERNODE_AUDIO_IN=$device
export INFERNODE_AUDIO_OUT=$device

expected=$(awk -F'\t' -v id="$FIXTURE" '$1==id{print $2}' "$FIXTUREDIR/utterances.tsv")
keywords=$(awk -F'\t' -v id="$FIXTURE" '$1==id{print $3}' "$FIXTUREDIR/utterances.tsv")
[ -n "$keywords" ] || fail "fixture $FIXTURE has no expected keywords in utterances.tsv"
echo "fixture $FIXTURE: $expected"

: >"$log"
tools/speech-test.sh -d -w -n 1 -e >"$log" 2>&1 &
listener=$!

waited=0
until grep -q '^speechtest: listening on ' "$log"; do
	if [ "$waited" -ge "$READY_TIMEOUT" ]; then
		cat "$log"
		fail "the speech stack did not start listening within ${READY_TIMEOUT}s"
	fi
	kill -0 "$listener" 2>/dev/null || { cat "$log"; fail "the speech stack exited during startup"; }
	sleep 1
	waited=$((waited + 1))
done
echo "speech stack listening after ${waited}s"

# Give capture a moment to settle before speaking into it. A device that
# has just opened can drop its first blocks, which would clip the start
# of the utterance and cost the transcript its first word.
sleep 2

"$EMU" -r. /dis/sh.dis -c "
	bind -a '#A' /dev
	echo 'out rate $RATE chans 1 bits 16 enc pcm' > /dev/audioctl
	cat /$FIXTUREDIR/$FIXTURE.pcm > /dev/audio
" >"$playlog" 2>&1 || { cat "$playlog"; fail "playing the fixture into '$device' failed"; }
echo "fixture played into '$device'"

# Playback has stopped, so the device now carries digital silence. That
# is what the turn gate is waiting for; anything longer than this and the
# turn is not being committed at all.
waited=0
until grep -q '^final:' "$log"; do
	if [ "$waited" -ge "$FINAL_TIMEOUT" ]; then
		cat "$log"
		fail "no turn committed within ${FINAL_TIMEOUT}s of the fixture ending"
	fi
	sleep 1
	waited=$((waited + 1))
done

grep -q '^partial:' "$log" ||
	fail "a final arrived with no partials — the stack is not streaming from the device"

heard=$(grep -m1 '^final:' "$log" | sed 's/^final:[[:space:]]*//')
echo "heard: $heard"

hits=0
IFS=,
for word in $keywords; do
	grep -qi -- "$word" <<<"$heard" && hits=$((hits + 1))
done
unset IFS
[ "$hits" -ge "$MIN_KEYWORDS" ] ||
	fail "heard $hits of the expected keywords ($keywords), wanted $MIN_KEYWORDS: $heard"

echo "PASS: a committed speech fixture crossed '$device' and came back as a transcript, with no microphone"
echo "PASS"
