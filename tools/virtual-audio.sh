#!/usr/bin/env bash
#
# virtual-audio.sh — locate a loopback virtual audio device, so audio and
# microphone behaviour can be tested without a microphone or a speaker.
#
# A loopback device is a software audio driver that presents one output
# and one input wired to each other: whatever is played to the output
# arrives on the input, sample for sample, with no room, no speaker, and
# no microphone in the path. Point InferNode's capture at that input and
# playback at that output and you have a microphone that says exactly
# what the test tells it to say, on every run.
#
# It is not a mock. The audio crosses the real CoreAudio/SDL3 device
# path, the real /dev/audio, the real turn gate and the real speech
# helpers — only the transducers are gone. The same device can be routed
# to real speakers (a macOS Multi-Output Device, or the routing UI of the
# driver itself) if you want to hear what a test is playing.
#
# Preferred driver: BlackHole (github.com/ExistentialAudio/BlackHole,
# MIT). It is free, needs no running application, and installs
# non-interactively:
#
#     brew install --cask blackhole-2ch
#
# Rogue Amoeba's Loopback is accepted when present, but its device only
# carries audio while the Loopback application is running, so it is a
# poor default for an unattended run.
#
# Sourced, not executed:
#     . "$ROOT/tools/virtual-audio.sh"
#     device=$(va_require_device) || exit $?
#
# Override the choice with INFERNODE_VIRTUAL_AUDIO_DEVICE='<name>'.

# Devices we are prepared to call a loopback, most preferred first. The
# list is a whitelist on purpose: several virtual devices appear on both
# the input and the output side without looping anything back (a voice
# changer, a lighting-sync sink), and a test that picked one of those
# would fail in a way that looks like an audio regression.
VA_KNOWN_DEVICES=(
	"BlackHole 2ch"
	"BlackHole 16ch"
	"BlackHole 64ch"
	"Loopback Audio"
)

VA_INSTALL_HINT="install a loopback driver: brew install --cask blackhole-2ch"

va_emu() {
	if [ -n "${EMU:-}" ]; then
		echo "$EMU"
		return
	fi
	case "$(uname -s)" in
	Darwin) echo "${ROOT}/emu/MacOSX/o.emu" ;;
	Linux)  echo "${ROOT}/emu/Linux/o.emu" ;;
	*)      echo "" ;;
	esac
}

# The device list comes from #A/audiodev rather than from the host's own
# tooling, because what matters is the set of devices InferNode can
# actually select. A device CoreAudio lists but SDL3 does not enumerate
# is not usable here, and a test should skip rather than fail on it.
va_enumerate() {
	local emu
	emu=$(va_emu)
	[ -x "$emu" ] || return 1
	"$emu" -r. /dis/sh.dis -c "bind -a '#A' /dev; cat /dev/audiodev" 2>/dev/null
}

# Echo the name of a loopback device present on both the input and the
# output side, or nothing. Both sides are required: a name that appears
# on only one of them cannot carry a signal from playback to capture.
va_find_device() {
	local listing want
	listing=$(va_enumerate) || return 1

	if [ -n "${INFERNODE_VIRTUAL_AUDIO_DEVICE:-}" ]; then
		want=$INFERNODE_VIRTUAL_AUDIO_DEVICE
		if grep -qF "in device '$want'" <<<"$listing" &&
		   grep -qF "out device '$want'" <<<"$listing"; then
			echo "$want"
			return 0
		fi
		return 1
	fi

	for want in "${VA_KNOWN_DEVICES[@]}"; do
		if grep -qF "in device '$want'" <<<"$listing" &&
		   grep -qF "out device '$want'" <<<"$listing"; then
			echo "$want"
			return 0
		fi
	done
	return 1
}

# Echo the device name, or print a skip reason and exit 77 — the status
# tools/speech-regress.sh reads as "skipped", not "failed". A missing
# driver is a property of the machine, not of the tree under test.
va_require_device() {
	local device
	if ! va_enumerate >/dev/null 2>&1; then
		echo "SKIP: no emulator with audio device selection ($VA_INSTALL_HINT)" >&2
		exit 77
	fi
	if ! device=$(va_find_device); then
		if [ -n "${INFERNODE_VIRTUAL_AUDIO_DEVICE:-}" ]; then
			echo "SKIP: INFERNODE_VIRTUAL_AUDIO_DEVICE='$INFERNODE_VIRTUAL_AUDIO_DEVICE' is not present on both the input and the output side" >&2
		else
			echo "SKIP: no virtual loopback audio device on this host — $VA_INSTALL_HINT" >&2
		fi
		exit 77
	fi
	echo "$device"
}

# ffmpeg's avfoundation input addresses devices by index, and the
# indices shift as headphones and phones come and go, so resolve the name
# to an index at the moment of use rather than hard-coding one.
va_avfoundation_index() {
	local want=$1
	ffmpeg -f avfoundation -list_devices true -i "" 2>&1 |
		awk -v want="$want" -F'] ' '
			/AVFoundation audio devices/ { audio = 1; next }
			audio && $3 == want { print substr($2, 2); exit }'
}

# Raw signed 16-bit little-endian mono PCM of a sine wave, for proving
# the loop carries a signal before any speech is put through it.
va_make_tone() {
	local path=$1 rate=$2 seconds=$3 freq=${4:-440} amp=${5:-12000}
	python3 - "$path" "$rate" "$seconds" "$freq" "$amp" <<'PY'
import math, struct, sys
path, rate, seconds, freq, amp = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), int(sys.argv[5])
with open(path, 'wb') as f:
    f.write(b''.join(struct.pack('<h', int(amp * math.sin(2 * math.pi * freq * i / rate)))
                     for i in range(int(rate * seconds))))
PY
}

# Report the share of a recording's energy that sits at one frequency,
# and its overall RMS, as "<fraction> <rms>". A loopback that carries the
# tone concentrates the energy; a dead device returns zeros; a device
# that picked up the room instead spreads the energy across the band.
va_tone_energy() {
	local path=$1 rate=$2 freq=$3
	python3 - "$path" "$rate" "$freq" <<'PY'
import math, struct, sys
path, rate, freq = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
raw = open(path, 'rb').read()
n = len(raw) // 2
if n == 0:
    print("0.0 0.0")
    raise SystemExit
s = struct.unpack(f"<{n}h", raw[:n * 2])
total = sum(float(v) * v for v in s)
if total == 0.0:
    print("0.0 0.0")
    raise SystemExit
# Goertzel: energy at one bin without paying for a whole transform.
w = 2.0 * math.pi * freq / rate
coeff, s1, s2 = 2.0 * math.cos(w), 0.0, 0.0
for v in s:
    s0 = v + coeff * s1 - s2
    s2, s1 = s1, s0
power = s1 * s1 + s2 * s2 - coeff * s1 * s2
print(f"{min(1.0, power / total / (n / 2.0)):.4f} {math.sqrt(total / n) / 32768.0:.5f}")
PY
}
