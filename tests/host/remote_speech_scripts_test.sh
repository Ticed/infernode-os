#!/usr/bin/env bash
# Lifecycle and cleanup contract for the Phase 2 remote speech launch scripts.

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

check_mounted_failure_cleanup() {
	name=$1
	source_port=$2
	source=$3
	mountpoint=$4
	state=$5
	expected=$6
	setup=$7
	command=$8
	out=$(timeout 8 "$EMU" -r"$ROOT" /dis/sh.dis -c \
		"load std; rm -rf $source $mountpoint; mkdir -p $source; $setup; listen -As 'tcp!*!$source_port' {export $source} &; sleep 1; $command; echo STATE; cat $state; if {ftest -e $mountpoint/sentinel} {echo STALE_MOUNT} {echo MOUNT_CLEAN}; echo DONE" 2>&1 || true)
	rm -rf "$ROOT$source" "$ROOT$mountpoint" "$ROOT$state"
	if ! grep -q 'DONE' <<<"$out" || ! grep -q "$expected" <<<"$out"; then
		echo "FAIL: $name did not publish the expected mounted failure" >&2
		echo "$out" | tail -30 >&2
		exit 1
	fi
	if ! grep -q '^MOUNT_CLEAN$' <<<"$out" || grep -q '^STALE_MOUNT$' <<<"$out"; then
		echo "FAIL: $name left its failed remote mount attached" >&2
		echo "$out" | tail -30 >&2
		exit 1
	fi
	passed=$((passed + 1))
	echo "PASS: $name removes its failed remote mount ($expected)"
}

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
rm -rf "$ROOT/tmp/remote-engine-term" "$ROOT/tmp/remote-engine-provider" \
	"$ROOT/tmp/remote-capture" "$ROOT/tmp/remote-terminal-provider"
rm -f "$ROOT/tmp/remote-engine-fail.state" \
	"$ROOT/tmp/remote-capture-fail.state" \
	"$ROOT/tmp/remote-terminal-fail.state" \
	"$ROOT/tmp/remote-terminal-fail.state.listener"

cleanup_base=$((32000 + $$ % 10000))
cleanup_tag=$$
check_mounted_failure_cleanup speech-engine "$cleanup_base" \
	/tmp/engine-noaudio-$cleanup_tag /tmp/engine-cleanup-mnt-$cleanup_tag \
	/tmp/engine-cleanup-$cleanup_tag.state '^failed audio ' \
	"echo sentinel > /tmp/engine-noaudio-$cleanup_tag/sentinel" \
	"sh /lib/voice/speech-engine 'tcp!127.0.0.1!$cleanup_base' $((cleanup_base + 1)) /tmp/engine-cleanup-mnt-$cleanup_tag /tmp/engine-cleanup-provider-$cleanup_tag 1 /tmp/engine-cleanup-$cleanup_tag.state"

check_mounted_failure_cleanup speech-capture "$((cleanup_base + 2))" \
	/tmp/capture-noaudio-$cleanup_tag /tmp/capture-cleanup-mnt-$cleanup_tag \
	/tmp/capture-cleanup-$cleanup_tag.state '^failed audio ' \
	"echo sentinel > /tmp/capture-noaudio-$cleanup_tag/sentinel" \
	"sh /lib/voice/speech-capture 'tcp!127.0.0.1!$((cleanup_base + 2))' /tmp/capture-cleanup-mnt-$cleanup_tag 1 /tmp/capture-cleanup-$cleanup_tag.state /tmp/capture-cleanup-$cleanup_tag.ctl"

check_mounted_failure_cleanup speech-capture "$((cleanup_base + 3))" \
	/tmp/capture-audio-$cleanup_tag /tmp/capture-control-mnt-$cleanup_tag \
	/tmp/capture-control-$cleanup_tag.state '^failed control ' \
	"echo sentinel > /tmp/capture-audio-$cleanup_tag/sentinel; echo audio > /tmp/capture-audio-$cleanup_tag/audio" \
	"sh /lib/voice/speech-capture 'tcp!127.0.0.1!$((cleanup_base + 3))' /tmp/capture-control-mnt-$cleanup_tag 1 /tmp/capture-control-$cleanup_tag.state /tmp/missing-control-$cleanup_tag/ctl"
rm -rf "$ROOT/tmp/engine-cleanup-provider-$cleanup_tag" \
	"$ROOT/tmp/missing-control-$cleanup_tag"
rm -f "$ROOT/tmp/capture-cleanup-$cleanup_tag.ctl" \
	"$ROOT/tmp/capture-control-$cleanup_tag.ctl"

# Force the engine's provider listener to fail after speechshim9p is running.
# The launcher must unmount both namespaces and stop the entire shim group.
engine_source_port=$((cleanup_base + 6))
engine_conflict_port=$((cleanup_base + 7))
engine_source=/tmp/engine-listener-source-$cleanup_tag
engine_term_mnt=/tmp/engine-listener-term-$cleanup_tag
engine_provider=/tmp/engine-listener-provider-$cleanup_tag
engine_state=/tmp/engine-listener-$cleanup_tag.state
engine_listener_out=$(timeout 10 "$EMU" -r"$ROOT" /dis/sh.dis -c \
	"load std; rm -rf $engine_source $engine_term_mnt $engine_provider; mkdir -p $engine_source /tmp/engine-conflict-$cleanup_tag; echo sentinel > $engine_source/sentinel; echo audio > $engine_source/audio; listen -As 'tcp!*!$engine_source_port' {export $engine_source} &; listen -As 'tcp!*!$engine_conflict_port' {export /tmp/engine-conflict-$cleanup_tag} &; sleep 1; sh /lib/voice/speech-engine 'tcp!127.0.0.1!$engine_source_port' $engine_conflict_port $engine_term_mnt $engine_provider 1 $engine_state; echo STATE; cat $engine_state; if {ftest -e $engine_term_mnt/sentinel} {echo STALE_TERM_MOUNT} {echo TERM_MOUNT_CLEAN}; if {ftest -e $engine_provider/ctl} {echo STALE_SHIM_MOUNT} {echo SHIM_MOUNT_CLEAN}; if {ps | grep Speechshim9p > /dev/null} {echo STALE_SHIM_PROCESS} {echo SHIM_PROCESS_CLEAN}; echo DONE" 2>&1 || true)
rm -rf "$ROOT$engine_source" "$ROOT$engine_term_mnt" "$ROOT$engine_provider" \
	"$ROOT$engine_state" "$ROOT/tmp/engine-conflict-$cleanup_tag"
if ! grep -q '^failed provider listener ' <<<"$engine_listener_out" || \
	! grep -q '^TERM_MOUNT_CLEAN$' <<<"$engine_listener_out" || \
	! grep -q '^SHIM_MOUNT_CLEAN$' <<<"$engine_listener_out" || \
	! grep -q '^SHIM_PROCESS_CLEAN$' <<<"$engine_listener_out"; then
	echo "FAIL: speech-engine did not clean up after provider-listener failure" >&2
	echo "$engine_listener_out" | tail -40 >&2
	exit 1
fi
passed=$((passed + 1))
echo "PASS: speech-engine cleans mounts and shim workers after listener failure"

capture_exhaust_port=$((cleanup_base + 8))
capture_exhaust_out=$(timeout 20 "$EMU" -r"$ROOT" /dis/sh.dis \
	/tests/inferno/remote_speech_capture_exhaustion.sh \
	"$capture_exhaust_port" "$cleanup_tag" 2>&1 || true)
rm -rf "$ROOT/tmp/capture-exhaust-source-$cleanup_tag" \
	"$ROOT/tmp/capture-exhaust-mount-$cleanup_tag"
rm -f "$ROOT/tmp/capture-exhaust-$cleanup_tag.state" \
	"$ROOT/tmp/capture-exhaust-$cleanup_tag.state.watcher" \
	"$ROOT/tmp/capture-exhaust-$cleanup_tag.ctl"
if ! grep -q '^CAPTURE_EXHAUSTED$' <<<"$capture_exhaust_out" || \
	! grep -q '^CAPTURE_MOUNT_CLEAN$' <<<"$capture_exhaust_out" || \
	! grep -q '^CAPTURE_WATCHER_CLEAN$' <<<"$capture_exhaust_out"; then
	echo "FAIL: speech-capture retry exhaustion was not bounded and clean" >&2
	echo "$capture_exhaust_out" | tail -40 >&2
	exit 1
fi
passed=$((passed + 1))
echo "PASS: speech-capture exhaustion removes its mount and watcher"

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
exhaust_port=$((restart_port + 4))
exhaust_audio_port=$((restart_port + 5))
exhaust_provider=/tmp/exhaust-provider-$restart_tag
exhaust_terminal_provider=/tmp/exhaust-terminal-provider-$restart_tag
exhaust_terminal_state=/tmp/exhaust-terminal-$restart_tag.state
exhaust_terminal_speech=/tmp/exhaust-terminal-speech-$restart_tag
provider_pid=
terminal_pid=
rejected_provider_pid=
terminal_cleanup_pid=
exhaust_provider_pid=
exhaust_terminal_pid=
cancel_probe_pid=

cleanup_restart_test() {
	[ -n "$provider_pid" ] && kill "$provider_pid" 2>/dev/null || true
	[ -n "$terminal_pid" ] && kill "$terminal_pid" 2>/dev/null || true
	[ -n "$rejected_provider_pid" ] && kill "$rejected_provider_pid" 2>/dev/null || true
	[ -n "$terminal_cleanup_pid" ] && kill "$terminal_cleanup_pid" 2>/dev/null || true
	[ -n "$exhaust_provider_pid" ] && kill "$exhaust_provider_pid" 2>/dev/null || true
	[ -n "$exhaust_terminal_pid" ] && kill "$exhaust_terminal_pid" 2>/dev/null || true
	[ -n "$cancel_probe_pid" ] && kill "$cancel_probe_pid" 2>/dev/null || true
	[ -n "$provider_pid" ] && wait "$provider_pid" 2>/dev/null || true
	[ -n "$terminal_pid" ] && wait "$terminal_pid" 2>/dev/null || true
	[ -n "$rejected_provider_pid" ] && wait "$rejected_provider_pid" 2>/dev/null || true
	[ -n "$terminal_cleanup_pid" ] && wait "$terminal_cleanup_pid" 2>/dev/null || true
	[ -n "$exhaust_provider_pid" ] && wait "$exhaust_provider_pid" 2>/dev/null || true
	[ -n "$exhaust_terminal_pid" ] && wait "$exhaust_terminal_pid" 2>/dev/null || true
	[ -n "$cancel_probe_pid" ] && wait "$cancel_probe_pid" 2>/dev/null || true
	rm -rf "$restart_tmp"
	rm -rf "$ROOT$restart_provider" "$ROOT$restart_terminal_provider" \
		"$ROOT$restart_terminal_speech" "$ROOT$rejected_provider" \
		"$ROOT$rejected_terminal_provider" "$ROOT$exhaust_provider" \
		"$ROOT$exhaust_terminal_provider" "$ROOT$exhaust_terminal_speech" \
		"$ROOT/tmp/terminal-cleanup-provider-$cleanup_tag" \
		"$ROOT/tmp/terminal-rebind-$cleanup_tag" \
		"$ROOT/tmp/terminal-rebind-client-$cleanup_tag" \
		"$ROOT/tmp/terminal-exhaust-rebind-$restart_tag" \
		"$ROOT/tmp/exhaust-client-$restart_tag" \
		"$ROOT/tmp/terminal-cancel-rebind-$restart_tag" \
		"$ROOT/tmp/cancel-client-$restart_tag"
	rm -f "$ROOT$restart_terminal_state" "$ROOT$rejected_terminal_state" \
		"$ROOT$rejected_speech_ctl" "$ROOT$exhaust_terminal_state" \
		"$ROOT$exhaust_terminal_state.listener" \
		"$ROOT$restart_terminal_state.listener" \
		"$ROOT$rejected_terminal_state.listener" \
		"$ROOT/tmp/terminal-cleanup-$cleanup_tag.state" \
		"$ROOT/tmp/terminal-cleanup-$cleanup_tag.state.listener" \
		"$ROOT/tmp/terminal-cleanup-$cleanup_tag.ctl"
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
	"load std; echo ready > $rejected_speech_ctl; sh /lib/voice/speech-terminal 'tcp!127.0.0.1!$rejected_port' $rejected_audio_port $rejected_terminal_provider 3 $rejected_terminal_state $rejected_speech_ctl; echo STATE; cat $rejected_terminal_state; if {ftest -e $rejected_terminal_provider/chime} {echo STALE_PROVIDER_MOUNT} {echo PROVIDER_MOUNT_CLEAN}; echo DONE" 2>&1 || true)
if ! grep -q "failed control $rejected_terminal_provider/ctl" <<<"$rejected_out"; then
	echo "FAIL: speech-terminal accepted a provider without writable ctl" >&2
	echo "$rejected_out" | tail -20 >&2
	exit 1
fi
if grep -q '^connected provider ' <<<"$rejected_out"; then
	echo "FAIL: speech-terminal published connected after provider ctl failure" >&2
	exit 1
fi
if ! grep -q '^PROVIDER_MOUNT_CLEAN$' <<<"$rejected_out"; then
	echo "FAIL: speech-terminal retained the rejected provider mount" >&2
	echo "$rejected_out" | tail -20 >&2
	exit 1
fi
kill "$rejected_provider_pid"
wait "$rejected_provider_pid" || true
rejected_provider_pid=
passed=$((passed + 1))
echo "PASS: speech-terminal rejects a provider without writable ctl"

# A failed terminal launch must stop the audio child, not merely return while
# leaving the port occupied.  Rebind the same port inside the same emulator and
# prove a second emulator sees the replacement export rather than stale /dev.
terminal_cleanup_port=$((cleanup_base + 4))
terminal_cleanup_dead=$((cleanup_base + 5))
terminal_cleanup_root=/tmp/terminal-rebind-$cleanup_tag
terminal_cleanup_log=$restart_tmp/terminal-cleanup.log
"$EMU" -r"$ROOT" /dis/sh.dis -c \
	"sh /lib/voice/speech-terminal 'tcp!127.0.0.1!$terminal_cleanup_dead' $terminal_cleanup_port /tmp/terminal-cleanup-provider-$cleanup_tag 1 /tmp/terminal-cleanup-$cleanup_tag.state /tmp/terminal-cleanup-$cleanup_tag.ctl; mkdir -p $terminal_cleanup_root; echo REBOUND_$cleanup_tag > $terminal_cleanup_root/token; echo TERMINAL_REBIND_READY; listen -As 'tcp!*!$terminal_cleanup_port' {export $terminal_cleanup_root}" \
	>"$terminal_cleanup_log" 2>&1 &
terminal_cleanup_pid=$!
if ! wait_for_log "$terminal_cleanup_log" '^TERMINAL_REBIND_READY$' 6; then
	echo "FAIL: speech-terminal did not reach its post-failure cleanup probe" >&2
	tail -30 "$terminal_cleanup_log" >&2
	exit 1
fi
sleep 1
terminal_cleanup_out=$(timeout 6 "$EMU" -r"$ROOT" /dis/sh.dis -c \
	"mkdir -p /tmp/terminal-rebind-client-$cleanup_tag; mount -A 'tcp!127.0.0.1!$terminal_cleanup_port' /tmp/terminal-rebind-client-$cleanup_tag; cat /tmp/terminal-rebind-client-$cleanup_tag/token" 2>&1 || true)
if ! grep -q "^REBOUND_$cleanup_tag$" <<<"$terminal_cleanup_out"; then
	echo "FAIL: speech-terminal left its failed audio listener on port $terminal_cleanup_port" >&2
	tail -30 "$terminal_cleanup_log" >&2
	echo "$terminal_cleanup_out" | tail -20 >&2
	exit 1
fi
kill "$terminal_cleanup_pid"
wait "$terminal_cleanup_pid" || true
terminal_cleanup_pid=
passed=$((passed + 1))
echo "PASS: speech-terminal removes its failed audio listener"

# Let a connected terminal exhaust its bounded provider retries.  The real
# watcher must unmount the dead provider, close the audio announce endpoint,
# and make the same port reusable without restarting the terminal emulator.
exhaust_provider_log=$restart_tmp/exhaust-provider.log
exhaust_terminal_log=$restart_tmp/exhaust-terminal.log
"$EMU" -r"$ROOT" /dis/sh.dis -c \
	"mkdir -p $exhaust_provider; echo 'duplex full' > $exhaust_provider/ctl; echo ready > $exhaust_provider/chime; listen -As 'tcp!*!$exhaust_port' {export $exhaust_provider}" \
	>"$exhaust_provider_log" 2>&1 &
exhaust_provider_pid=$!
"$EMU" -r"$ROOT" /dis/sh.dis \
	/tests/inferno/remote_speech_terminal_exhaustion.sh \
	"tcp!127.0.0.1!$exhaust_port" "$exhaust_audio_port" \
	"$exhaust_terminal_provider" "$exhaust_terminal_state" \
	"$exhaust_terminal_speech" "$restart_tag" \
	>"$exhaust_terminal_log" 2>&1 &
exhaust_terminal_pid=$!
if ! wait_for_log "$exhaust_terminal_log" '^TERMINAL_EXHAUST_INITIAL$' 12; then
	echo "FAIL: exhaustion terminal did not establish its initial mount" >&2
	tail -30 "$exhaust_provider_log" "$exhaust_terminal_log" >&2
	exit 1
fi
kill "$exhaust_provider_pid"
wait "$exhaust_provider_pid" || true
exhaust_provider_pid=
if ! wait_for_log "$exhaust_terminal_log" '^TERMINAL_EXHAUST_REBIND_READY$' 12; then
	echo "FAIL: speech-terminal did not finish bounded retry cleanup" >&2
	tail -40 "$exhaust_terminal_log" >&2
	exit 1
fi
if ! grep -q '^TERMINAL_PROVIDER_MOUNT_CLEAN$' "$exhaust_terminal_log" || \
	! grep -q '^TERMINAL_ENDPOINT_CLEAN$' "$exhaust_terminal_log"; then
	echo "FAIL: speech-terminal exhaustion retained provider state" >&2
	tail -40 "$exhaust_terminal_log" >&2
	exit 1
fi
sleep 1
exhaust_client_out=$(timeout 6 "$EMU" -r"$ROOT" /dis/sh.dis -c \
	"mkdir -p /tmp/exhaust-client-$restart_tag; mount -A 'tcp!127.0.0.1!$exhaust_audio_port' /tmp/exhaust-client-$restart_tag; cat /tmp/exhaust-client-$restart_tag/token" 2>&1 || true)
if ! grep -q "^TERMINAL_REBOUND_$restart_tag$" <<<"$exhaust_client_out"; then
	echo "FAIL: speech-terminal exhaustion left its audio port occupied" >&2
	tail -40 "$exhaust_terminal_log" >&2
	echo "$exhaust_client_out" | tail -20 >&2
	exit 1
fi
kill "$exhaust_terminal_pid"
wait "$exhaust_terminal_pid" || true
exhaust_terminal_pid=
passed=$((passed + 1))
echo "PASS: speech-terminal exhaustion cleans mounts, state, and listener"

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

# The host process is the faithful service-supervision boundary for explicit
# cancellation.  Reap it, then prove its exported audio port is immediately
# available to a replacement service.
kill "$terminal_pid"
wait "$terminal_pid" || true
terminal_pid=
cancel_probe_root=/tmp/terminal-cancel-rebind-$restart_tag
cancel_probe_log=$restart_tmp/cancel-probe.log
"$EMU" -r"$ROOT" /dis/sh.dis -c \
	"mkdir -p $cancel_probe_root; echo CANCEL_REBOUND_$restart_tag > $cancel_probe_root/token; echo CANCEL_REBIND_READY; listen -As 'tcp!*!$restart_audio_port' {export $cancel_probe_root}" \
	>"$cancel_probe_log" 2>&1 &
cancel_probe_pid=$!
if ! wait_for_log "$cancel_probe_log" '^CANCEL_REBIND_READY$' 6; then
	echo "FAIL: cancellation replacement service did not start" >&2
	tail -30 "$cancel_probe_log" >&2
	exit 1
fi
sleep 1
cancel_client_out=$(timeout 6 "$EMU" -r"$ROOT" /dis/sh.dis -c \
	"mkdir -p /tmp/cancel-client-$restart_tag; mount -A 'tcp!127.0.0.1!$restart_audio_port' /tmp/cancel-client-$restart_tag; cat /tmp/cancel-client-$restart_tag/token" 2>&1 || true)
if ! grep -q "^CANCEL_REBOUND_$restart_tag$" <<<"$cancel_client_out"; then
	echo "FAIL: cancelled terminal emulator retained its audio port" >&2
	tail -30 "$cancel_probe_log" >&2
	echo "$cancel_client_out" | tail -20 >&2
	exit 1
fi
kill "$cancel_probe_pid"
wait "$cancel_probe_pid" || true
cancel_probe_pid=
passed=$((passed + 1))
echo "PASS: service cancellation reaps the terminal and releases its listener"

echo "remote_speech_scripts_test: $passed passed"
