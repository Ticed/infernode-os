#!/usr/bin/env bash
#
# A whole voice turn over one device: wake word, utterance, spoken reply.
#
# The loopback device stands in for a speaker and a microphone wired to
# the same machine, which is what a laptop actually is. So this covers
# the parts of voice mode that only exist when playback and capture
# share a device:
#
#   - the wake word arriving as sound rather than as a byte stream. The
#     helper's own detection can be checked offline; that it fires on
#     audio that crossed the device cannot.
#   - the reply reaching the device at all. "say done" returns as soon
#     as the write is queued, so the log alone never proved a sound was
#     made.
#   - half-duplex suppression (speechshim9p). The reply is on the input
#     the instant it is played here, exactly as a speaker feeds a
#     microphone in a room. If suppression lapsed, the stack would
#     transcribe its own voice and answer itself. Nothing else in the
#     tree can put the reply back on the capture path to check that.
#
# The wake word and the utterance are played as one stream, the way a
# person says "hey jarvis" and keeps talking: the gap between them is
# shorter than the turn gate's silence window, so both land in one turn.
#
# See docs/SPEECH-VIRTUAL-AUDIO.md.
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
log="$TMP/virtual-voice-turn.log"
speech="$TMP/virtual-voice-turn-speech.pcm"
reply="$TMP/virtual-voice-turn-reply.pcm"

WAKE=tests/fixtures/speech/kokoro/hey_jarvis.pcm
FIXTUREDIR=tests/fixtures/speech/elevenlabs
FIXTURE=${VIRTUAL_MIC_FIXTURE:-voice_submit}
PHRASE='Local speech is working correctly.'
RATE=16000
GAP_MS=250              # shorter than the turn gate's silence window
READY_TIMEOUT=90        # the listen helper loads a model on first start
FINAL_TIMEOUT=25
REPLY_TIMEOUT=20
QUIET_AFTER_REPLY=8     # long enough for a lapsed suppression to answer itself
MIN_KEYWORDS=2
MIN_REPLY_RMS=0.02      # a spoken reply against a silent virtual device

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
[ -s "$WAKE" ] || fail "missing wake fixture $WAKE"
[ -s "$FIXTUREDIR/$FIXTURE.pcm" ] || fail "missing fixture $FIXTUREDIR/$FIXTURE.pcm"
command -v ffmpeg >/dev/null 2>&1 ||
	skip "recording the reply needs ffmpeg (brew install ffmpeg)"

device=$(va_require_device) || exit $?
echo "virtual audio device: $device"
export INFERNODE_AUDIO_IN=$device
export INFERNODE_AUDIO_OUT=$device

keywords=$(awk -F'\t' -v id="$FIXTURE" '$1==id{print $3}' "$FIXTUREDIR/utterances.tsv")
[ -n "$keywords" ] || fail "fixture $FIXTURE has no expected keywords in utterances.tsv"

# One stream: wake word, a gap too short to end a turn, then the request.
cat "$WAKE" > "$speech"
head -c $((RATE * 2 * GAP_MS / 1000)) /dev/zero >> "$speech"
cat "$FIXTUREDIR/$FIXTURE.pcm" >> "$speech"

: >"$log"
tools/speech-test.sh -d -w -n 2 -p "$PHRASE" >"$log" 2>&1 &
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
sleep 2   # a device that has just opened can drop its first blocks

"$EMU" -r. /dis/sh.dis -c "
	bind -a '#A' /dev
	echo 'out rate $RATE chans 1 bits 16 enc pcm' > /dev/audioctl
	cat /$speech > /dev/audio
" >"$TMP/virtual-voice-turn-play.log" 2>&1 ||
	{ cat "$TMP/virtual-voice-turn-play.log"; fail "playing into '$device' failed"; }
echo "wake word and utterance played into '$device'"

# Playback has stopped, so from here the device carries only what the
# stack itself puts on it. Record the whole reply window.
rm -f "$reply"
ffmpeg -hide_banner -loglevel error -f avfoundation \
	-i ":$(va_avfoundation_index "$device")" -t "$REPLY_TIMEOUT" \
	-f s16le -ar "$RATE" -ac 1 "$reply" &
recorder=$!

waited=0
until grep -q '^wake:' "$log"; do
	[ "$waited" -ge 5 ] && { cat "$log"; fail "the wake word did not reach the helper across the device"; }
	sleep 1
	waited=$((waited + 1))
done
grep -m1 '^wake:' "$log"

waited=0
until grep -q '^final:' "$log"; do
	if [ "$waited" -ge "$FINAL_TIMEOUT" ]; then
		cat "$log"
		fail "no turn committed within ${FINAL_TIMEOUT}s of the utterance ending"
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

waited=0
until grep -q '^say:' "$log"; do
	[ "$waited" -ge "$REPLY_TIMEOUT" ] && { cat "$log"; fail "the stack never answered the turn"; }
	sleep 1
	waited=$((waited + 1))
done

wait "$recorder" 2>/dev/null || true
[ -s "$reply" ] || fail "recording '$device' produced nothing"

# The stack was the only thing playing during this window, so any signal
# here is the reply. Measure the loudest part rather than the whole
# window, which is mostly the silence around it.
loudest=$(python3 - "$reply" "$RATE" <<'PY'
import struct, sys
raw = open(sys.argv[1], 'rb').read()
rate = int(sys.argv[2])
n = len(raw) // 2
s = struct.unpack(f"<{n}h", raw[:n * 2])
win = rate // 4
best = 0.0
for i in range(0, max(1, n - win), win):
    block = s[i:i + win]
    if block:
        best = max(best, (sum(float(v) * v for v in block) / len(block)) ** 0.5 / 32768.0)
print(f"{best:.5f}")
PY
)
echo "loudest 250 ms of the reply: rms $loudest"
awk -v got="$loudest" -v want="$MIN_REPLY_RMS" 'BEGIN{exit !(got >= want)}' ||
	fail "the reply never reached '$device' (loudest rms $loudest < $MIN_REPLY_RMS) — 'say done' only means the write was queued"

# Half-duplex: the reply was on the capture side the whole time it played.
# A second final here would mean the stack answered its own voice.
sleep "$QUIET_AFTER_REPLY"
finals=$(grep -c '^final:' "$log")
[ "$finals" -eq 1 ] ||
	fail "$finals turns committed; the stack transcribed its own reply — half-duplex suppression is not holding"

echo "PASS: wake word, utterance and spoken reply all crossed '$device', and the stack did not answer itself"
echo "PASS"
