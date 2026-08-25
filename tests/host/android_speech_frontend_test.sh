#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/android-speech-frontend.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

mkdir -p "$TMP/bin"
ADB_LOG="$TMP/adb.log"
NC_LOG="$TMP/nc.log"
export ADB_LOG NC_LOG

# The launcher now preflights helpers, models, and playback with the SDK
# checks. Give it a complete fake prefix so this test stays hermetic.
SPEECH_HOME="$TMP/speech"
mkdir -p "$SPEECH_HOME/bin" "$SPEECH_HOME/models/kokoro" "$SPEECH_HOME/models/parakeet"
touch "$SPEECH_HOME/bin/kokoro-cli" "$SPEECH_HOME/bin/openwakeword-cli" \
	"$SPEECH_HOME/bin/whisper-stream-cli"
chmod +x "$SPEECH_HOME/bin/kokoro-cli" "$SPEECH_HOME/bin/openwakeword-cli" \
	"$SPEECH_HOME/bin/whisper-stream-cli"
touch "$SPEECH_HOME/models/kokoro/kokoro-v1.0.onnx" \
	"$SPEECH_HOME/models/kokoro/voices-v1.0.bin" \
	"$SPEECH_HOME/models/ggml-base.en.bin"
PLAYBACK_LIST="$TMP/playback.list"
echo 'Test Speakers' > "$PLAYBACK_LIST"
export INFERNODE_SPEECH_HOME="$SPEECH_HOME"
export ANDROID_PREFLIGHT_PLAYBACK_LIST="$PLAYBACK_LIST"


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
	if [ "${FAKE_ADB_MODE:-one}" = no-ip ]; then
		exit 1
	fi
	echo '42: tailscale0    inet 100.84.91.15/32 scope global tailscale0' ;;
*' shell ip -4 -o addr show wlan0') exit 1 ;;
*' shell dumpsys activity services io.infernode')
	if [ "${FAKE_MIC_SERVICE:-running}" = running ]; then
		echo '  * ServiceRecord{0 u0 io.infernode/.InfernodeSpeechMicService}'
		echo '    isForeground=true foregroundServiceType=microphone'
	fi ;;
*' shell dumpsys audio')
	echo 'Audio event log: recording activity received by AudioService'
	case "${FAKE_MIC_STATE:-audible}" in
	silenced)
		echo '08-16 04:49:56:127 rec update riid:2383 uid:10409 session:3585 src:VOICE_RECOGNITION silenced pack:io.infernode' ;;
	stale)
		# A session that has already ended. Its verdict describes the
		# past, not the microphone the next run will get.
		echo '08-16 04:53:23:104 rec stop riid:2407 uid:10409 session:3705 src:VOICE_RECOGNITION silenced pack:io.infernode' ;;
	*)
		echo '08-16 04:51:48:588 rec update riid:2391 uid:10409 session:3625 src:VOICE_RECOGNITION not silenced pack:io.infernode' ;;
	esac ;;
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
check "verifies the microphone foreground service is held" \
	grep -q 'shell dumpsys activity services io.infernode' "$ADB_LOG"
check "verifies Android has not silenced capture" \
	grep -q 'shell dumpsys audio' "$ADB_LOG"
check "reports the microphone as authorized" \
	grep -q 'microphone: authorized' "$TMP/launch.out"

# A reachable 9P port proves nothing about capture: Android silences the
# microphone without erroring, so /dev/audio keeps serving zeros and the
# Mac-side STT times out with no diagnosis. Both silent-failure modes must
# stop the launcher instead of printing "ready".
if FAKE_MIC_STATE=silenced ADB="$TMP/bin/adb" NC="$TMP/bin/nc" \
	"$ROOT/tools/android-speech-frontend.sh" --ip 100.84.91.15 --wait 0 \
	> "$TMP/silenced.out" 2> "$TMP/silenced.err"; then
	silenced_rc=1
else
	silenced_rc=0
fi
check "fails when Android has silenced the microphone" test "$silenced_rc" -eq 0
check "explains the silenced-microphone failure" \
	grep -q 'silenced' "$TMP/silenced.err"
if grep -q 'is ready' "$TMP/silenced.out"; then
	ready_leak=1
else
	ready_leak=0
fi
check "does not report readiness when capture is silenced" test "$ready_leak" -eq 0

# At launch nothing has opened /dev/audio yet, so the newest recording event
# is normally a finished session from a previous run. Treating that as the
# current verdict makes the launcher refuse to start a perfectly good phone.
if ADB="$TMP/bin/adb" NC="$TMP/bin/nc" FAKE_MIC_STATE=stale \
	"$ROOT/tools/android-speech-frontend.sh" --ip 100.84.91.15 --wait 0 \
	> "$TMP/stale.out" 2>&1; then
	stale_rc=0
else
	stale_rc=1
fi
check "ignores a silenced verdict from an ended session" test "$stale_rc" -eq 0
check "still reports readiness after a stale silenced verdict" \
	grep -q 'is ready' "$TMP/stale.out"

if FAKE_MIC_SERVICE=absent ADB="$TMP/bin/adb" NC="$TMP/bin/nc" \
	"$ROOT/tools/android-speech-frontend.sh" --ip 100.84.91.15 --wait 0 \
	> "$TMP/nomic.out" 2> "$TMP/nomic.err"; then
	nomic_rc=1
else
	nomic_rc=0
fi
check "fails when the microphone foreground service is absent" test "$nomic_rc" -eq 0
check "explains the missing foreground service" \
	grep -q 'InfernodeSpeechMicService' "$TMP/nomic.err"

# The service and its manifest type are the fix; a build that drops either
# regresses to the silent-zero failure, so assert them here rather than
# waiting for a physical acoustic run to time out again.
check "manifest declares the microphone foreground service type" \
	grep -q 'android:foregroundServiceType="microphone"' \
	"$ROOT/android-app/app/src/main/AndroidManifest.xml"
check "manifest requests FOREGROUND_SERVICE_MICROPHONE" \
	grep -q 'android.permission.FOREGROUND_SERVICE_MICROPHONE' \
	"$ROOT/android-app/app/src/main/AndroidManifest.xml"
check "speech-export mode holds the microphone service" \
	grep -q 'InfernodeSpeechMicService.start(this)' \
	"$ROOT/android-app/app/src/main/java/io/infernode/InfernodeSDLActivity.kt"
check "speech-export mode keeps the activity visible" \
	grep -q 'FLAG_KEEP_SCREEN_ON' \
	"$ROOT/android-app/app/src/main/java/io/infernode/InfernodeSDLActivity.kt"

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

# USB needs no IP route to the phone: adb forward makes the export appear
# at 127.0.0.1. The fake device has neither tailscale0 nor wlan0.
: > "$ADB_LOG"
: > "$NC_LOG"
if FAKE_ADB_MODE=no-ip ADB="$TMP/bin/adb" NC="$TMP/bin/nc" \
	"$ROOT/tools/android-speech-frontend.sh" --transport usb --wait 0 \
	> "$TMP/usb.out" 2> "$TMP/usb.err"; then
	usb_rc=0
else
	usb_rc=1
fi
check "usb transport launches without a phone IP" test "$usb_rc" -eq 0
check "usb prints the localhost mount address" \
	grep -q 'address: tcp!127.0.0.1!17010' "$TMP/usb.out"
check "usb sets up adb forward" \
	grep -q 'forward tcp:17010 tcp:17010' "$ADB_LOG"
check "usb probes localhost" \
	grep -q -- '-z -w 1 127.0.0.1 17010' "$NC_LOG"
check "usb does not query phone interfaces" \
	test "$(grep -c 'addr show' "$ADB_LOG" || true)" -eq 0
check "usb still grants microphone permission" \
	grep -q 'shell pm grant io.infernode android.permission.RECORD_AUDIO' "$ADB_LOG"
check "usb still verifies the microphone foreground service" \
	grep -q 'shell dumpsys activity services io.infernode' "$ADB_LOG"
check "usb still verifies Android has not silenced capture" \
	grep -q 'shell dumpsys audio' "$ADB_LOG"
check "usb reports the microphone as authorized" \
	grep -q 'microphone: authorized' "$TMP/usb.out"

# --stop tears down the host-side forward even without --transport usb:
# the forward is keyed by this port, not by how the next invocation
# would reach the phone.
: > "$ADB_LOG"
FAKE_ADB_MODE=no-ip ADB="$TMP/bin/adb" NC="$TMP/bin/nc" \
	"$ROOT/tools/android-speech-frontend.sh" --stop > "$TMP/usb-stop.out"
check "stop removes the adb forward" \
	grep -q 'forward --remove tcp:17010' "$ADB_LOG"
check "stop force-stops the package" \
	grep -q 'shell am force-stop io.infernode' "$ADB_LOG"

if ADB="$TMP/bin/adb" NC="$TMP/bin/nc" \
	"$ROOT/tools/android-speech-frontend.sh" --transport pigeon \
	> /dev/null 2>&1; then
	invalid_transport=1
else
	invalid_transport=0
fi
check "rejects an invalid transport" test "$invalid_transport" -eq 0

echo "android_speech_frontend_test: $pass passed, $fail failed"
test "$fail" -eq 0
