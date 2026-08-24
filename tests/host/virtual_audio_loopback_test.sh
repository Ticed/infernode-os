#!/usr/bin/env bash
#
# The virtual audio rig, checked against itself: play a tone out of
# InferNode into a loopback device and capture it back in, with no
# speaker and no microphone anywhere in the path.
#
# This is the foundation the microphone-free speech tests stand on
# (virtual_mic_speech_test.sh). If the loop does not carry a tone, a
# speech test running over it would fail for a reason that has nothing
# to do with speech, so prove the carrier first and separately.
#
# It is also the only test in the tree that exercises playback as
# something other than "did the write return". Until there was a device
# that could hear what InferNode plays, the output path could only be
# checked by a person listening to it.
set -euo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
cd "$ROOT"
export ROOT
export PATH="$ROOT/MacOSX/arm64/bin:$PATH"

. "$ROOT/tools/virtual-audio.sh"

EMU=$(va_emu)
TMP=${AUDIO_TEST_TMPDIR:-.omx/tmp}
mkdir -p "$TMP"
log="$TMP/virtual-audio-loopback.log"
tone="$TMP/va-tone.pcm"
cap="$TMP/va-capture.pcm"

RATE=16000
FREQ=440
# A tone concentrated at one frequency; anything the room could have
# contributed would be spread across the band instead.
MIN_TONE_FRACTION=0.30
MIN_RMS=0.02

fail() { echo "FAIL: $1"; exit 1; }
skip() { echo "SKIP: $1"; exit 77; }

device=$(va_require_device) || exit $?
echo "virtual audio device: $device"

va_make_tone "$tone" "$RATE" 4 "$FREQ"
rm -f "$cap"

# One emulator drives both directions: playback in the background for
# longer than the capture runs, so the capture window sits inside the
# tone rather than straddling its start or its end.
export INFERNODE_AUDIO_IN=$device
export INFERNODE_AUDIO_OUT=$device
"$EMU" -r. /dis/sh.dis -c "
	bind -a '#A' /dev
	echo 'out rate $RATE chans 1 bits 16 enc pcm' > /dev/audioctl
	echo 'in rate $RATE chans 1 bits 16 enc pcm' > /dev/audioctl
	cat /$tone > /dev/audio &
	sleep 1
	dd -if /dev/audio -of /$cap -bs 3200 -count 8
	cat /dev/audiodev
" >"$log" 2>&1 || true
cat "$log"

grep -qF "in selected '$device'" "$log" ||
	fail "the environment did not select '$device' for capture"
grep -qF "out selected '$device'" "$log" ||
	fail "the environment did not select '$device' for playback"

[ -s "$cap" ] || skip "the loopback device delivered no data (microphone authorization is required even for a virtual input)"

read -r fraction rms <<<"$(va_tone_energy "$cap" "$RATE" "$FREQ")"
echo "captured: ${fraction} of the energy at ${FREQ} Hz, rms ${rms}"

if grep -q '^capture silent' "$log"; then
	case "$device" in
	BlackHole*)
		# A muted device presents itself normally and passes zeros,
		# which is indistinguishable from a broken driver until you
		# look. Its volume is a device property, so it survives
		# reboots and is not visible in the output most people check.
		fail "'$device' captured only silence — the loopback driver is not carrying playback to capture.
	Check first that the device is not muted:
	    SwitchAudioSource -t output -s '$device'
	    osascript -e 'set volume output volume 100' -e 'set volume without output muted'
	    SwitchAudioSource -t output -s 'MacBook Pro Speakers'" ;;
	*)
		skip "'$device' captured only silence; this driver carries audio only while its application is running — $VA_INSTALL_HINT" ;;
	esac
fi
grep -q '^capture active' "$log" || fail "no capture verdict after a capture"

awk -v got="$rms" -v want="$MIN_RMS" 'BEGIN{exit !(got >= want)}' ||
	fail "captured signal is too quiet (rms $rms < $MIN_RMS) — the loop is attenuating or dropping audio"
awk -v got="$fraction" -v want="$MIN_TONE_FRACTION" 'BEGIN{exit !(got >= want)}' ||
	fail "only $fraction of the captured energy is at $FREQ Hz — the input is not carrying what was played"

echo "PASS: a tone played by InferNode came back through '$device' with no microphone"
echo "PASS"
