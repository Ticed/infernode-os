#!/bin/sh
# Canonical speech bootstrap: one sealed path, seal before the agent grant.
#
# Two checks:
#   1. Launcher pin — lib/sh/profile must not start speech9p; Lucifer boot
#      must run boot-speech.sh before tools9p; boot-speech.sh must not pass -U.
#      A grep pin cannot prove the script works; the runtime check below can.
#   2. Runtime — run boot-speech.sh inside emu, assert the mount is sealed
#      *before* tools9p is started, then start tools9p with say/hear and
#      assert the seal still holds.
#
# Does not open the microphone or the speakers: it only reads and writes ctl.
set -e

. "$(dirname "$0")/common.sh"

fail=0

# --- 1. Launcher pin -------------------------------------------------
if grep -E '/dis/veltro/speech9p' "$ROOT/lib/sh/profile" >/dev/null 2>&1; then
    echo "FAIL: lib/sh/profile still starts speech9p"
    fail=1
else
    echo "PASS: lib/sh/profile does not start speech9p"
fi

starts=$(grep -E '/dis/veltro/speech9p' "$ROOT/lib/lucifer/"*.sh 2>/dev/null | grep -v '^[^:]*:#' || true)
case "$starts" in
    *boot-speech.sh*)
        echo "PASS: the only lucifer speech9p start is boot-speech.sh"
        ;;
    *)
        echo "FAIL: lucifer speech start is not confined to boot-speech.sh"
        echo "$starts"
        fail=1
        ;;
esac
if echo "$starts" | grep -v boot-speech.sh | grep -q speech9p; then
    echo "FAIL: a lucifer script other than boot-speech.sh starts speech9p"
    echo "$starts"
    fail=1
fi

if grep -E -- '-U' "$ROOT/lib/lucifer/boot-speech.sh" >/dev/null 2>&1; then
    echo "FAIL: boot-speech.sh passes -U (would publish an unsealed server)"
    fail=1
else
    echo "PASS: boot-speech.sh does not pass -U"
fi
if ! grep -q 'echo seal on' "$ROOT/lib/lucifer/boot-speech.sh"; then
    echo "FAIL: boot-speech.sh does not write seal on"
    fail=1
else
    echo "PASS: boot-speech.sh writes seal on"
fi

boot="$ROOT/lib/lucifer/boot.sh"
speech_line=$(grep -n '^run /lib/lucifer/boot-speech.sh' "$boot" | head -1 | cut -d: -f1)
tools_line=$(grep -n '/dis/veltro/tools9p' "$boot" | head -1 | cut -d: -f1)
if [ -z "$speech_line" ] || [ -z "$tools_line" ]; then
    echo "FAIL: boot.sh is missing boot-speech.sh or tools9p"
    fail=1
elif [ "$speech_line" -ge "$tools_line" ]; then
    echo "FAIL: boot.sh runs tools9p at line $tools_line before boot-speech.sh at line $speech_line"
    fail=1
else
    echo "PASS: boot.sh runs boot-speech.sh (line $speech_line) before tools9p (line $tools_line)"
fi

if [ ! -x "$EMU" ]; then
    echo "SKIP: emu not found at $EMU (launcher pin ran)"
    [ "$fail" -eq 0 ] || exit 1
    exit 77
fi
if [ ! -f "$ROOT/dis/veltro/speech9p.dis" ]; then
    echo "SKIP: dis/veltro/speech9p.dis not built"
    [ "$fail" -eq 0 ] || exit 1
    exit 77
fi

# --- 2. Runtime: seal before grant -----------------------------------
mkdir -p "$ROOT/tmp" 2>/dev/null || true
# A leftover host file at the mount point would swallow ctl writes.
# The log/sentinel live under tmp/ so a killed emu still leaves the
# result on the host filesystem (emu stdout is block-buffered).
rm -rf "$ROOT/n/speech" "$ROOT/tmp/speech-grant-tool" \
    "$ROOT/tmp/speech_bootstrap_done" "$ROOT/tmp/speech_bootstrap_log" 2>/dev/null || true

cat > "$ROOT/tmp/speech_bootstrap_testscript.sh" << 'INFERNO'
load std
path=(/dis .)

fn log {
	echo $1 >> /tmp/speech_bootstrap_log
}
fn finish {
	log '=== SCRIPT DONE ==='
	echo done > /tmp/speech_bootstrap_done
}

run /lib/lucifer/boot-speech.sh

if {! ftest -f /n/speech/ctl} {
	log 'FAIL: boot-speech.sh did not publish /n/speech/ctl'
	finish
	raise fail:speech-bootstrap
}

cfg := `{cat /n/speech/ctl}
if {! ~ $"cfg *'seal on'*} {
	log 'FAIL: boot-speech.sh published an unsealed server'
	finish
	raise fail:speech-bootstrap
}
log 'PASS: bootstrap sealed before tools9p'

before := `{cat /n/speech/ctl}
echo 'cmdtts /bin/echo pwned' > /n/speech/ctl
echo 'engine api' > /n/speech/ctl
after := `{cat /n/speech/ctl}
if {! ~ $"before $"after} {
	log 'FAIL: sealed keys changed before the grant'
	finish
	raise fail:speech-bootstrap
}
log 'PASS: sealed keys unchanged before the grant'

# The grant: tools9p serving say/hear. Seal must already be on, and stay on.
/dis/veltro/tools9p -v -m /tmp/speech-grant-tool say hear >[2] /dev/null &
mounted=0
for i in 1 2 3 4 5 6 7 8 9 10 {
	if {~ $mounted 0} {
		if {ftest -d /tmp/speech-grant-tool} {
			mounted=1
		} {
			sleep 1
		}
	}
}
if {~ $mounted 0} {
	log 'FAIL: tools9p did not mount (grant never existed)'
	finish
	raise fail:speech-bootstrap
}
log 'PASS: tools9p grant exists after the seal'

echo 'cmdtts /bin/echo granted' > /n/speech/ctl
echo 'engine api' > /n/speech/ctl
aftergrant := `{cat /n/speech/ctl}
if {! ~ $"aftergrant *'seal on'*} {
	log 'FAIL: seal dropped after the grant'
	finish
	raise fail:speech-bootstrap
}
if {~ $"aftergrant *'engine api'*} {
	log 'FAIL: engine changed after the grant'
	finish
	raise fail:speech-bootstrap
}
if {~ $"aftergrant *'granted'*} {
	log 'FAIL: cmdtts accepted after the grant'
	finish
	raise fail:speech-bootstrap
}
log 'PASS: seal held after the grant'
finish
INFERNO

OUT=$(mktemp /tmp/speech_bootstrap_test_out.XXXXXX)
"$EMU" -r"$ROOT" -c0 sh /tmp/speech_bootstrap_testscript.sh > "$OUT" 2>&1 &
EMU_PID=$!
i=0
while [ $i -lt 45 ]; do
    if [ -f "$ROOT/tmp/speech_bootstrap_done" ]; then
        break
    fi
    if ! kill -0 "$EMU_PID" 2>/dev/null; then
        break
    fi
    sleep 1
    i=$((i + 1))
done
kill "$EMU_PID" 2>/dev/null || true
wait "$EMU_PID" 2>/dev/null || true

LOG="$ROOT/tmp/speech_bootstrap_log"
if [ ! -f "$ROOT/tmp/speech_bootstrap_done" ]; then
    echo "FAIL: test script did not run to completion"
    fail=1
fi
if [ -f "$LOG" ] && grep -q '^FAIL' "$LOG"; then
    echo "FAIL: bootstrap assertions failed"
    fail=1
fi
if [ ! -f "$LOG" ] || ! grep -q 'PASS: bootstrap sealed before tools9p' "$LOG"; then
    echo "FAIL: missing seal-before-grant assertion"
    fail=1
fi
if [ ! -f "$LOG" ] || ! grep -q 'PASS: seal held after the grant' "$LOG"; then
    echo "FAIL: missing seal-after-grant assertion"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "--- bootstrap log ---"
    cat "$LOG" 2>/dev/null || true
    echo "--- emulator output ---"
    cat "$OUT"
    rm -f "$OUT"
    exit 1
fi
rm -f "$OUT"
echo "PASS: canonical speech bootstrap is sealed before the grant"
exit 0
