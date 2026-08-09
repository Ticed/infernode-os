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

# Run provider and terminal in separate emulator processes so killing the
# provider closes the real host TCP socket.  The terminal-side shell waits on
# speech-terminal's state file inside its own namespace, then performs a chime
# write through the recovered mount before publishing a host-visible marker.
restart_port=$((22000 + $$ % 10000))
restart_audio_port=$((restart_port + 1))
restart_tmp=$(mktemp -d "${TMPDIR:-/tmp}/remote-speech-restart.XXXXXX") || exit 1
restart_tag=$$
restart_provider=/tmp/restart-provider-$restart_tag
restart_terminal_provider=/tmp/restart-terminal-provider-$restart_tag
restart_terminal_state=/tmp/restart-terminal-$restart_tag.state
restart_terminal_speech=/tmp/restart-terminal-speech-$restart_tag
rejected_provider=/tmp/rejected-provider-$restart_tag
rejected_terminal_provider=/tmp/rejected-terminal-provider-$restart_tag
rejected_terminal_state=/tmp/rejected-terminal-$restart_tag.state
rejected_speech_ctl=/tmp/rejected-speech-$restart_tag.ctl
rejected_port=$((restart_port + 2))
rejected_audio_port=$((restart_port + 3))
provider_pid=
terminal_pid=
rejected_provider_pid=

cleanup_restart_test() {
	[ -n "$provider_pid" ] && kill "$provider_pid" 2>/dev/null || true
	[ -n "$terminal_pid" ] && kill "$terminal_pid" 2>/dev/null || true
	[ -n "$rejected_provider_pid" ] && kill "$rejected_provider_pid" 2>/dev/null || true
	[ -n "$provider_pid" ] && wait "$provider_pid" 2>/dev/null || true
	[ -n "$terminal_pid" ] && wait "$terminal_pid" 2>/dev/null || true
	[ -n "$rejected_provider_pid" ] && wait "$rejected_provider_pid" 2>/dev/null || true
	rm -rf "$restart_tmp"
	rm -rf "$ROOT$restart_provider" "$ROOT$restart_terminal_provider" \
		"$ROOT$restart_terminal_speech" "$ROOT$rejected_provider" \
		"$ROOT$rejected_terminal_provider"
	rm -f "$ROOT$restart_terminal_state" "$ROOT$rejected_terminal_state" \
		"$ROOT$rejected_speech_ctl"
}
trap cleanup_restart_test EXIT

wait_for_log() {
	file=$1
	pattern=$2
	limit=$3
	i=0
	while [ "$i" -lt $((limit * 5)) ]; do
		grep -q "$pattern" "$file" 2>/dev/null && return 0
		sleep 0.2
		i=$((i + 1))
	done
	return 1
}

# A reachable exported tree without a provider ctl is not a usable speech
# provider.  The terminal must fail closed instead of trusting speech9p's
# acknowledgement of its own local ctl write.
rejected_provider_log=$restart_tmp/rejected-provider.log
"$EMU" -r"$ROOT" /dis/sh.dis -c \
	"mkdir -p $rejected_provider; echo ready > $rejected_provider/chime; echo REJECTED_PROVIDER_READY; listen -As 'tcp!*!$rejected_port' {export $rejected_provider}" \
	>"$rejected_provider_log" 2>&1 &
rejected_provider_pid=$!
if ! wait_for_log "$rejected_provider_log" '^REJECTED_PROVIDER_READY$' 5; then
	echo "FAIL: rejected-control provider did not start" >&2
	tail -20 "$rejected_provider_log" >&2
	exit 1
fi
rejected_out=$(timeout 10 "$EMU" -r"$ROOT" /dis/sh.dis -c \
	"echo ready > $rejected_speech_ctl; sh /lib/voice/speech-terminal 'tcp!127.0.0.1!$rejected_port' $rejected_audio_port $rejected_terminal_provider 3 $rejected_terminal_state $rejected_speech_ctl; echo STATE; cat $rejected_terminal_state; echo DONE" 2>&1 || true)
if ! grep -q "failed control $rejected_terminal_provider/ctl" <<<"$rejected_out"; then
	echo "FAIL: speech-terminal accepted a provider without writable ctl" >&2
	echo "$rejected_out" | tail -20 >&2
	exit 1
fi
if grep -q '^connected provider ' <<<"$rejected_out"; then
	echo "FAIL: speech-terminal published connected after provider ctl failure" >&2
	exit 1
fi
kill "$rejected_provider_pid"
wait "$rejected_provider_pid" || true
rejected_provider_pid=
passed=$((passed + 1))
echo "PASS: speech-terminal rejects a provider without writable ctl"

start_provider() {
	provider_log=$1
	"$EMU" -r"$ROOT" /dis/sh.dis -c \
		"mkdir -p $restart_provider; echo 'duplex full' > $restart_provider/ctl; echo ready > $restart_provider/chime; listen -As 'tcp!*!$restart_port' {export $restart_provider}" \
		>"$provider_log" 2>&1 &
	provider_pid=$!
}

provider_log_1=$restart_tmp/provider-1.log
provider_log_2=$restart_tmp/provider-2.log
terminal_log=$restart_tmp/terminal.log
start_provider "$provider_log_1"

"$EMU" -r"$ROOT" /dis/sh.dis /tests/inferno/remote_speech_terminal_recovery.sh \
	"tcp!127.0.0.1!$restart_port" "$restart_audio_port" \
	"$restart_terminal_provider" "$restart_terminal_state" \
	"$restart_terminal_speech" \
	>"$terminal_log" 2>&1 &
terminal_pid=$!

if ! wait_for_log "$terminal_log" '^TERMINAL_INITIAL$' 12; then
	echo "FAIL: terminal did not establish its initial provider mount" >&2
	tail -30 "$provider_log_1" "$terminal_log" >&2
	exit 1
fi
if grep -q '^TERMINAL_ROUTING_FAILED$' "$terminal_log"; then
	echo "FAIL: terminal did not apply its initial speech routing" >&2
	tail -30 "$provider_log_1" "$terminal_log" >&2
	exit 1
fi

kill "$provider_pid"
wait "$provider_pid"
provider_exit=$?
provider_pid=
echo "INFO: killed provider emulator exit=$provider_exit"

if ! wait_for_log "$terminal_log" '^TERMINAL_WAITING$' 8; then
	echo "FAIL: speech-terminal did not publish a waiting retry after provider death" >&2
	tail -30 "$terminal_log" >&2
	exit 1
fi

start_provider "$provider_log_2"
if ! wait_for_log "$terminal_log" '^PROVIDER_OPERATION_OK$' 12; then
	echo "FAIL: terminal did not remount and use the restarted provider" >&2
	tail -30 "$provider_log_2" "$terminal_log" >&2
	exit 1
fi
if grep -q '^PROVIDER_OPERATION_FAILED$' "$terminal_log"; then
	echo "FAIL: recovered provider operation failed" >&2
	tail -30 "$terminal_log" >&2
	exit 1
fi
passed=$((passed + 1))
echo "PASS: speech-terminal remounts after provider emulator restart"

echo "remote_speech_scripts_test: $passed passed"
