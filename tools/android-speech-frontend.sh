#!/bin/sh
# Launch an InferNode Android device as a remote microphone frontend.
#
# The phone exports /dev over unauthenticated 9P for development. The Mac
# imports only /dev/audio through speech-capture; processing and playback stay
# on the Mac. --transport ip (default) prefers Tailscale, then Wi-Fi.
# --transport usb uses adb forward to 127.0.0.1 and needs no phone IP route.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PKG=io.infernode
ADB=${ADB:-adb}
NC=${NC:-nc}

device=
phone_ip=
phone_iface=
port=17010
wait_seconds=30
install=0
stop=0
transport=ip
apk="$ROOT/android-app/app/build/outputs/apk/debug/app-debug.apk"

. "$ROOT/tools/android-speech-preflight.sh"


usage()
{
	cat <<'EOF'
usage: tools/android-speech-frontend.sh [options]

  --device SERIAL    adb device serial (auto-selected when exactly one exists)
  --ip ADDRESS       phone address (auto-detects tailscale0, then wlan0)
  --transport usb|ip usb: adb forward to 127.0.0.1; ip: phone address (default)
  --port PORT        development 9P port (default: 17010)
  --install          install/reinstall the default debug APK before launch
  --apk PATH         install this APK before launch (implies --install)
  --wait SECONDS     connection probe timeout (default: 30)
  --stop             stop the InferNode Android process and exit
  -h, --help         show this help

The export is intentionally unauthenticated for Phase 2 development. Use a
trusted local or Tailscale network only. The final security audit must replace
this transport before release.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--device) device=$2; shift 2 ;;
	--device=*) device=${1#*=}; shift ;;
	--ip) phone_ip=$2; shift 2 ;;
	--ip=*) phone_ip=${1#*=}; shift ;;
	--transport) transport=$2; shift 2 ;;
	--transport=*) transport=${1#*=}; shift ;;
	--port) port=$2; shift 2 ;;
	--port=*) port=${1#*=}; shift ;;
	--wait) wait_seconds=$2; shift 2 ;;
	--wait=*) wait_seconds=${1#*=}; shift ;;
	--install) install=1; shift ;;
	--apk) apk=$2; install=1; shift 2 ;;
	--apk=*) apk=${1#*=}; install=1; shift ;;
	--stop) stop=1; shift ;;
	-h|--help) usage; exit 0 ;;
	*) echo "android-speech-frontend: unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

case "$port" in
''|*[!0-9]*) echo "android-speech-frontend: invalid port: $port" >&2; exit 2 ;;
esac
if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
	echo "android-speech-frontend: invalid port: $port" >&2
	exit 2
fi
case "$wait_seconds" in
''|*[!0-9]*) echo "android-speech-frontend: invalid wait: $wait_seconds" >&2; exit 2 ;;
esac

case "$transport" in
ip|usb) ;;
*) echo "android-speech-frontend: invalid transport: $transport" >&2; exit 2 ;;
esac
if [ "$transport" = usb ]; then
	# USB presents the export at 127.0.0.1 via adb forward.
	phone_ip=127.0.0.1
fi

if [ "$stop" -eq 0 ]; then
	android_preflight_init
	android_preflight_check_helpers
	android_preflight_check_playback
else
	android_preflight_init
fi

android_preflight_find_adb
if [ -n "$android_preflight_adb" ]; then
	ADB=$android_preflight_adb
else
	_sdk=${android_preflight_sdk:-}
	[ -n "$_sdk" ] || { android_preflight_find_sdk; _sdk=$android_preflight_sdk; }
	android_preflight_add_error \
		"adb" \
		"\$ADB, adb on PATH, ${_sdk:-~/Library/Android/sdk}/platform-tools/adb" \
		"install Android platform-tools, or use the copy under the resolved SDK"
fi

if [ -n "${ADB:-}" ] && command -v "$ADB" >/dev/null 2>&1; then
	if [ -z "$device" ]; then
		devices=$($ADB devices | awk 'NR > 1 && $2 == "device" { print $1 }')
		# Intentional word splitting: adb serials cannot contain whitespace.
		set -- $devices
		case "$#" in
		0) android_preflight_add_error \
			"authorized adb device" \
			"adb devices" \
			"enable USB debugging, authorize this computer, or pass --device SERIAL" ;;
		1) device=$1 ;;
		*) android_preflight_add_error \
			"adb device selection" \
			"multiple devices: $*" \
			"pass --device SERIAL" ;;
		esac
	fi

	if [ -n "$device" ]; then
		if ! "$ADB" -s "$device" get-state 2>/dev/null | grep -q '^device'; then
			android_preflight_add_error \
				"adb device ready" \
				"adb -s $device get-state" \
				"unlock the phone and re-authorize USB debugging"
		fi
	fi
fi

if [ "$stop" -eq 1 ]; then
	android_preflight_finish || exit 1
	"$ADB" -s "$device" forward --remove "tcp:$port" >/dev/null 2>&1 || true
	"$ADB" -s "$device" shell am force-stop "$PKG"
	echo "Stopped $PKG on $device."
	exit 0
fi

if [ "$install" -eq 1 ] && [ ! -f "$apk" ]; then
	android_preflight_add_error \
		"debug APK" \
		"$apk" \
		"./build-android-apk.sh --gui sdl3 --abi arm64-v8a"
fi

if [ -n "$device" ] && [ "$install" -eq 0 ]; then
	if ! "$ADB" -s "$device" shell pm path "$PKG" 2>/dev/null | grep -q '^package:'; then
		android_preflight_add_error \
			"$PKG is not installed" \
			"adb -s $device shell pm path $PKG" \
			"pass --install after building the APK"
	fi
fi

if [ "$transport" != usb ] && [ -z "$phone_ip" ] && [ -n "$device" ]; then
	for iface in tailscale0 wlan0; do
		phone_ip=$("$ADB" -s "$device" shell ip -4 -o addr show "$iface" 2>/dev/null |
			sed -n 's/.* inet \([0-9.]*\)\/.*/\1/p' | head -n 1 | tr -d '\r')
		if [ -n "$phone_ip" ]; then
			phone_iface=$iface
			break
		fi
	done
	if [ -z "$phone_ip" ]; then
		android_preflight_add_error \
			"phone network reachability" \
			"adb -s $device shell ip -4 addr show tailscale0 / wlan0" \
			"join Tailscale on the phone, or the same Wi-Fi as this Mac, or pass --ip ADDRESS"
	fi
fi

android_preflight_finish || exit 1

if [ "$phone_iface" = wlan0 ]; then
	echo "note: Tailscale was not detected; using Wi-Fi address $phone_ip" >&2
fi

adb_device()
{
	"$ADB" -s "$device" "$@"
}

abi=$(adb_device shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')
if [ -z "$abi" ]; then
	echo "android-speech-frontend: could not read the device ABI" >&2
	exit 1
fi

if [ "$install" -eq 1 ]; then
	echo "Installing $(basename "$apk") on $device ($abi) ..."
	adb_device install -r "$apk" >/dev/null
fi

if ! adb_device shell pm path "$PKG" 2>/dev/null | grep -q '^package:'; then
	echo "android-speech-frontend: $PKG is not installed (pass --install)" >&2
	exit 1
fi

if ! adb_device shell pm grant "$PKG" android.permission.RECORD_AUDIO 2>/dev/null; then
	echo "android-speech-frontend: could not grant RECORD_AUDIO" >&2
	echo "unlock the phone, approve microphone access, and retry" >&2
	exit 1
fi



echo "Launching Android speech export on $phone_ip:$port ..."
adb_device shell am force-stop "$PKG"
adb_device shell am start -n "$PKG/.InfernodeSDLActivity" \
	--es io.infernode.extra.MODE speech-export \
	--ei io.infernode.extra.SPEECH_PORT "$port" >/dev/null

if [ "$transport" = usb ]; then
	if ! adb_device forward "tcp:$port" "tcp:$port" >/dev/null; then
		echo "android-speech-frontend: adb forward tcp:$port failed" >&2
		exit 1
	fi
fi

if ! command -v "$NC" >/dev/null 2>&1; then
	echo "android-speech-frontend: nc not found; launch sent but reachability is unverified" >&2
	exit 1
fi

elapsed=0
while ! "$NC" -z -w 1 "$phone_ip" "$port" >/dev/null 2>&1; do
	if [ "$elapsed" -ge "$wait_seconds" ]; then
		echo "android-speech-frontend: $phone_ip:$port did not become reachable" >&2
		echo "recent InferNode log:" >&2
		adb_device logcat -d -t 250 2>/dev/null |
			grep -E 'InferNode|audio-sdl3|FATAL EXCEPTION' | tail -n 40 >&2 || true
		exit 1
	fi
	sleep 1
	elapsed=$((elapsed + 1))
done

# Reachability is not capture. Android silences an app's microphone when it
# stops being in use, and the 9P export keeps serving at full rate either
# way — every sample is simply zero. That failure has no error to report at
# any layer, so the Mac-side STT just waits and a fixture run "times out".
# Never print "ready" without proving the microphone is actually authorized.

# Latest recording verdict for this package.
#
# `dumpsys audio` prints a historical event log, not current state, so the
# last line is only authoritative while its session is still open. A `rec
# stop` or `rec release` describes a session that has already ended — at
# launch nothing has opened /dev/audio yet, so the newest line is routinely
# a stale verdict from a previous run. Only `rec start` and `rec update`
# describe a live capture. " not silenced" must also be tested before
# " silenced": one string contains the other.
capture_silenced()
{
	verdict=$(adb_device shell dumpsys audio 2>/dev/null |
		grep 'pack:io.infernode' | tail -n 1 | tr -d '\r')
	case "$verdict" in
	*' rec start '*|*' rec update '*) ;;
	*) return 1 ;;
	esac
	case "$verdict" in
	*' not silenced '*) return 1 ;;
	*' silenced '*) return 0 ;;
	*) return 1 ;;
	esac
}

# The microphone-typed foreground service is what keeps capture authorized
# once the activity stops being visible. Without it, a screen timeout part
# way through a run is enough to zero the rest of the audio.
mic_service_running()
{
	adb_device shell dumpsys activity services io.infernode 2>/dev/null |
		grep -q 'InfernodeSpeechMicService'
}

waited=0
while ! mic_service_running; do
	if [ "$waited" -ge 10 ]; then
		echo "android-speech-frontend: InfernodeSpeechMicService is not running" >&2
		echo "capture would be silenced as soon as the activity stops being visible" >&2
		echo "reinstall the current APK: tools/android-speech-frontend.sh --install" >&2
		exit 1
	fi
	sleep 1
	waited=$((waited + 1))
done

if capture_silenced; then
	echo "android-speech-frontend: Android has silenced this app's microphone" >&2
	echo "captured audio would be digital zero, and STT would time out silently" >&2
	echo "unlock the phone, confirm the microphone permission, and relaunch" >&2
	exit 1
fi

cat <<EOF
Android speech frontend is ready.
  device: $device ($abi)
  address: tcp!$phone_ip!$port
  microphone: authorized (foreground service held; capture not silenced)
  security: unauthenticated development export; trusted/Tailscale networks only

Inside the processing Mac's InferNode namespace, run:
  sh /lib/voice/speech-capture tcp!$phone_ip!$port

Then verify:
  cat /tmp/speech-capture.state
Expected prefix:
  connected capture tcp!$phone_ip!$port

For a standalone headless proof using the installed local helpers:
  tools/speech-test.sh -M 'tcp!$phone_ip!$port /n/phone' \\
    -c 'capturedev /n/phone/audio' -c 'micmode device' -e -n 1
EOF
