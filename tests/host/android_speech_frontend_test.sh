#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/android-speech-frontend.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

mkdir -p "$TMP/bin"
ADB_LOG="$TMP/adb.log"
NC_LOG="$TMP/nc.log"
export ADB_LOG NC_LOG

cat > "$TMP/bin/adb" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$ADB_LOG"
if [ "$1" = devices ]; then
	echo 'List of devices attached'
	if [ "${FAKE_ADB_MODE:-one}" = multiple ]; then
		echo 'phone-one device'
		echo 'phone-two device'
	else
		echo 'phone-one device'
	fi
	exit 0
fi
case "$*" in
*' get-state') echo device ;;
*' shell getprop ro.product.cpu.abi') echo arm64-v8a ;;
*' shell pm path io.infernode') echo package:/data/app/io.infernode/base.apk ;;
*' shell ip -4 -o addr show tailscale0')
	echo '42: tailscale0    inet 100.84.91.15/32 scope global tailscale0' ;;
*' shell ip -4 -o addr show wlan0') exit 1 ;;
*' logcat '*) echo 'InferNode: test diagnostic' ;;
esac
exit 0
EOF

cat > "$TMP/bin/nc" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$NC_LOG"
exit 0
EOF
chmod +x "$TMP/bin/adb" "$TMP/bin/nc"

pass=0
fail=0
check()
{
	name=$1
	shift
	if "$@"; then
		echo "ok - $name"
		pass=$((pass + 1))
	else
		echo "not ok - $name"
		fail=$((fail + 1))
	fi
}

: > "$ADB_LOG"
: > "$NC_LOG"
ADB="$TMP/bin/adb" NC="$TMP/bin/nc" \
	"$ROOT/tools/android-speech-frontend.sh" --wait 0 > "$TMP/launch.out"
check "auto-detects the Tailscale address" \
	grep -q 'address: tcp!100.84.91.15!17010' "$TMP/launch.out"
check "launches the SDL speech-export mode" \
	grep -q -- '--es io.infernode.extra.MODE speech-export --ei io.infernode.extra.SPEECH_PORT 17010' "$ADB_LOG"
check "grants microphone permission" \
	grep -q 'shell pm grant io.infernode android.permission.RECORD_AUDIO' "$ADB_LOG"
check "probes the selected address" \
	grep -q -- '-z -w 1 100.84.91.15 17010' "$NC_LOG"

: > "$ADB_LOG"
: > "$TMP/app-debug.apk"
ADB="$TMP/bin/adb" NC="$TMP/bin/nc" \
	"$ROOT/tools/android-speech-frontend.sh" --device phone-one \
	--ip 100.84.91.15 --apk "$TMP/app-debug.apk" --wait 0 > /dev/null
check "installs an explicitly selected APK" \
	grep -q "install -r $TMP/app-debug.apk" "$ADB_LOG"

if ADB="$TMP/bin/adb" NC="$TMP/bin/nc" \
	"$ROOT/tools/android-speech-frontend.sh" --port 70000 > /dev/null 2>&1; then
	invalid_port=1
else
	invalid_port=0
fi
check "rejects an invalid port" test "$invalid_port" -eq 0

if FAKE_ADB_MODE=multiple ADB="$TMP/bin/adb" NC="$TMP/bin/nc" \
	"$ROOT/tools/android-speech-frontend.sh" > /dev/null 2>&1; then
	multiple_devices=1
else
	multiple_devices=0
fi
check "requires selection when multiple devices are attached" \
	test "$multiple_devices" -eq 0

echo "android_speech_frontend_test: $pass passed, $fail failed"
test "$fail" -eq 0
