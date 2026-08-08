#!/usr/bin/env bash
# Initial-failure contract for the Phase 2 remote speech launch scripts.

set -u

ROOT=${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
case "$(uname -s)" in
Darwin) emuhost=MacOSX ;;
Linux) emuhost=Linux ;;
*) echo "SKIP: unsupported host"; exit 77 ;;
esac
EMU=${EMU:-$ROOT/emu/$emuhost/o.emu}
[ -x "$EMU" ] || { echo "SKIP: emulator not built: $EMU"; exit 77; }

port=17998
passed=0

check_failure() {
	name=$1
	state=$2
	shift 2
	out=$(timeout 8 "$EMU" -r"$ROOT" /dis/sh.dis -c \
		"echo 'connected stale STALE_STATE_SUFFIX' > $state; sh /lib/voice/$name $*; echo STATE; cat $state; echo DONE" 2>&1 || true)
	if ! grep -q 'DONE' <<<"$out"; then
		echo "FAIL: $name did not return after its configured mount bound" >&2
		echo "$out" | tail -20 >&2
		exit 1
	fi
	if ! grep -q '^failed ' <<<"$out"; then
		echo "FAIL: $name did not expose a failed startup state" >&2
		echo "$out" | tail -20 >&2
		exit 1
	fi
	if grep -q 'STALE_STATE_SUFFIX' <<<"$out"; then
		echo "FAIL: $name retained stale bytes in its replacement state" >&2
		echo "$out" | tail -20 >&2
		exit 1
	fi
	passed=$((passed + 1))
	echo "PASS: $name initial mount failure is bounded and observable"
}

check_failure speech-engine /tmp/remote-engine-fail.state \
	"tcp!127.0.0.1!$port" 17999 /tmp/remote-engine-term \
	/tmp/remote-engine-provider 1 /tmp/remote-engine-fail.state

check_failure speech-capture /tmp/remote-capture-fail.state \
	"tcp!127.0.0.1!$port" /tmp/remote-capture 1 \
	/tmp/remote-capture-fail.state

# speech-terminal starts the audio export before dialing the provider. Its
# failed child listener can keep the emulator alive, so the DONE marker is the
# bounded script result; timeout remains a safety net for the test process.
check_failure speech-terminal /tmp/remote-terminal-fail.state \
	"tcp!127.0.0.1!$port" 17997 /tmp/remote-terminal-provider 1 \
	/tmp/remote-terminal-fail.state

echo "remote_speech_scripts_test: $passed passed"
