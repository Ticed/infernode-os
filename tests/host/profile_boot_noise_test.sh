#!/bin/sh
#
# The login profile settle-walks /n/local so trfs has the host root in
# cache before overlay binds. Those walks must not print the host
# filesystem to the user's terminal.
#
# Run from project root: ./tests/host/profile_boot_noise_test.sh

. "$(dirname "$0")/common.sh"

if [ ! -x "$EMU" ]; then
	echo "SKIP: emulator not found at $EMU"
	exit 77
fi
if [ ! -f "$ROOT/dis/sh.dis" ]; then
	echo "SKIP: Dis runtime not built (missing dis/sh.dis)"
	exit 77
fi

HOME=$(mktemp -d "${TMPDIR:-/tmp}/infernode-profile-noise.XXXXXX")
LOG=$(mktemp "${TMPDIR:-/tmp}/infernode-profile-noise.log.XXXXXX")
trap 'rm -rf "$HOME" "$LOG"' EXIT

SDL_VIDEODRIVER=dummy
SDL_AUDIODRIVER=dummy
export HOME SDL_VIDEODRIVER SDL_AUDIODRIVER

timeout 12 "$EMU" -c0 -r"$ROOT" /dis/sh.dis -l -c 'echo PROFILE_DONE' \
	</dev/null >"$LOG" 2>&1 || true

if ! grep -q 'PROFILE_DONE' "$LOG"; then
	echo 'FAIL: profile did not reach PROFILE_DONE'
	echo '--- log ---'
	cat "$LOG"
	exit 1
fi

if grep -q '/n/local/Applications' "$LOG" || grep -q '/n/local/Users' "$LOG"; then
	echo 'FAIL: profile printed the host root listing to stdout'
	echo '--- matching lines ---'
	grep '/n/local/' "$LOG" | head
	exit 1
fi

echo 'profile_boot_noise: PASS'
exit 0
