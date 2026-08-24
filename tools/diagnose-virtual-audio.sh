#!/usr/bin/env bash
#
# diagnose-virtual-audio.sh — find out which half of the audio path is silent.
#
# When a virtual audio device carries nothing, four things look identical
# from the outside: the emulator's playback, the emulator's capture, the
# driver itself, and microphone authorization. This walks the ladder that
# separates them, in the order that costs least, and prints a verdict.
#
#   tools/diagnose-virtual-audio.sh
#
# The step that catches most of it is the last one: a muted device is a
# perfect impostor. It enumerates on both sides, accepts playback, clocks
# the writes at real time, and hands its input nothing but zeros. Volume
# and mute are device properties, so they survive a reboot and are not
# visible in anything the emulator prints.
#
# See docs/SPEECH-VIRTUAL-AUDIO.md and docs/agents/voice-testing.md.
set -uo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
cd "$ROOT"
export ROOT
. "$ROOT/tools/virtual-audio.sh"

TMP=${AUDIO_TEST_TMPDIR:-.omx/tmp}
mkdir -p "$TMP"
EMU=$(va_emu)
RATE=16000
FREQ=440
SIGNAL=0.005            # rms above which a recording holds something

# Captured before anything switches devices, so the advice below names
# the speakers to go back to rather than whatever is selected by then.
DEFAULT_OUT=$(SwitchAudioSource -c -t output 2>/dev/null || echo "<your speakers>")

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

rms() { va_tone_energy "$1" "$RATE" "$FREQ" | awk '{print $2}'; }
loud() { awk -v got="$1" -v want="$SIGNAL" 'BEGIN{exit !(got >= want)}'; }

[ -x "$EMU" ] || { say "no emulator built at $EMU"; exit 1; }

step "1. is a loopback device visible to InferNode?"
if ! device=$(va_find_device); then
	say "   no. $VA_INSTALL_HINT"
	say "   InferNode sees:"
	va_enumerate | sed 's/^/     /'
	exit 1
fi
say "   yes: '$device'"

step "2. can the emulator capture at all? (microphone authorization)"
mic=$(va_enumerate | sed -n "s/^in device '\(.*Microphone\)'/\1/p" | head -1)
if [ -z "$mic" ]; then
	say "   no built-in microphone to test against; skipping"
else
	rm -f "$TMP/diag-mic.pcm"
	INFERNODE_AUDIO_IN="$mic" "$EMU" -r. /dis/sh.dis -c "
		bind -a '#A' /dev
		echo 'in rate $RATE chans 1 bits 16 enc pcm' > /dev/audioctl
		dd -if /dev/audio -of /$TMP/diag-mic.pcm -bs 3200 -count 8
	" >/dev/null 2>&1
	got=$(rms "$TMP/diag-mic.pcm")
	if loud "$got"; then
		say "   yes: '$mic' recorded room noise (rms $got)"
	else
		say "   NO: '$mic' recorded silence (rms $got)."
		say "   Grant the terminal Microphone permission; macOS records silence"
		say "   rather than failing when it is refused. Everything below would"
		say "   be silent for that reason alone."
		exit 1
	fi
fi

step "3. does the emulator's playback reach '$device'?"
va_make_tone "$TMP/diag-tone.pcm" "$RATE" 5 "$FREQ"
rm -f "$TMP/diag-host.pcm"
idx=$(va_avfoundation_index "$device")
if [ -z "$idx" ] || ! command -v ffmpeg >/dev/null 2>&1; then
	say "   skipped (needs ffmpeg to listen from the host side)"
else
	INFERNODE_AUDIO_OUT="$device" "$EMU" -r. /dis/sh.dis -c "
		bind -a '#A' /dev
		echo 'out rate $RATE chans 1 bits 16 enc pcm' > /dev/audioctl
		cat /$TMP/diag-tone.pcm > /dev/audio
	" >/dev/null 2>&1 &
	emupid=$!
	sleep 1
	ffmpeg -hide_banner -loglevel error -f avfoundation -i ":$idx" -t 2 \
		-f s16le -ar "$RATE" -ac 1 "$TMP/diag-host.pcm" >/dev/null 2>&1
	wait $emupid 2>/dev/null
	got=$(rms "$TMP/diag-host.pcm")
	if loud "$got"; then
		say "   yes: the host heard the tone on '$device' (rms $got)"
		emuplay=ok
	else
		say "   no: the host heard silence on '$device' (rms $got)"
		emuplay=silent
	fi
fi

step "4. does '$device' carry anything at all, host to host?"
if [ "${emuplay:-}" = ok ]; then
	say "   not needed — step 3 already proved the loop carries audio"
else
	orig=$(SwitchAudioSource -c -t output 2>/dev/null)
	if [ -z "$orig" ] || ! command -v afplay >/dev/null 2>&1; then
		say "   skipped (needs switchaudio-osx: brew install switchaudio-osx)"
	else
		trap 'SwitchAudioSource -t output -s "$orig" >/dev/null 2>&1' EXIT
		ffmpeg -hide_banner -loglevel error -y -f lavfi \
			-i "sine=frequency=$FREQ:sample_rate=48000:duration=5" -ac 2 \
			"$TMP/diag-tone.wav" >/dev/null 2>&1
		SwitchAudioSource -t output -s "$device" >/dev/null
		afplay "$TMP/diag-tone.wav" &
		playpid=$!
		sleep 1
		rm -f "$TMP/diag-loop.pcm"
		ffmpeg -hide_banner -loglevel error -f avfoundation -i ":$idx" -t 2 \
			-f s16le -ar "$RATE" -ac 1 "$TMP/diag-loop.pcm" >/dev/null 2>&1
		wait $playpid 2>/dev/null
		SwitchAudioSource -t output -s "$orig" >/dev/null
		trap - EXIT
		got=$(rms "$TMP/diag-loop.pcm")
		if loud "$got"; then
			say "   yes (rms $got) — the driver is fine, so the emulator's"
			say "   playback is the half that is not arriving."
		else
			say "   NO (rms $got): the driver itself is passing nothing."
			say "   Not an InferNode problem. Check step 5."
		fi
	fi
fi

step "5. is '$device' muted?"
if [ "${emuplay:-}" = ok ]; then
	say "   not asked — audio is flowing, so nothing here is muted."
	say ""
	say "Verdict: the path is healthy end to end."
	exit 0
fi
say "   Mute is a device property: it survives reboots, it is not shown by"
say "   #A/audiodev, and a muted device passes silence while looking healthy."
say "   It is the most likely cause of everything above being silent. Clear it:"
say "     SwitchAudioSource -t output -s '$device'"
say "     osascript -e 'set volume output volume 100' -e 'set volume without output muted'"
say "     SwitchAudioSource -t output -s '$DEFAULT_OUT'"
say ""
say "Then re-run: bash tests/host/virtual_audio_loopback_test.sh"
