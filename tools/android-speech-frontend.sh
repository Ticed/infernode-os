#!/bin/sh
# Launch an InferNode Android device as a remote microphone frontend.
#
# The phone exports /dev over unauthenticated 9P for development. The Mac
# imports only /dev/audio through speech-capture; processing and playback stay
# on the Mac. Prefer a Tailscale address and do not expose the port publicly.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PKG=io.infernode
ADB=${ADB:-adb}
NC=${NC:-nc}

device=
phone_ip=
port=17010
wait_seconds=30
install=0
stop=0
apk="$ROOT/android-app/app/build/outputs/apk/debug/app-debug.apk"

usage()
{
	cat <<'EOF'
usage: tools/android-speech-frontend.sh [options]

  --device SERIAL    adb device serial (auto-selected when exactly one exists)
  --ip ADDRESS       phone address (auto-detects tailscale0, then wlan0)
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

if ! command -v "$ADB" >/dev/null 2>&1; then
	echo "android-speech-frontend: adb not found (set ADB or install Android platform-tools)" >&2
	exit 1
fi

if [ -z "$device" ]; then
	devices=$($ADB devices | awk 'NR > 1 && $2 == "device" { print $1 }')
	# Intentional word splitting: adb serials cannot contain whitespace.
	set -- $devices
	case "$#" in
	0) echo "android-speech-frontend: no authorized adb device found" >&2; exit 1 ;;
	1) device=$1 ;;
	*) echo "android-speech-frontend: multiple adb devices; pass --device SERIAL" >&2; exit 1 ;;
	esac
fi

adb_device()
{
	"$ADB" -s "$device" "$@"
}

if ! adb_device get-state 2>/dev/null | grep -q '^device'; then
	echo "android-speech-frontend: device is not ready or authorized: $device" >&2
	exit 1
fi

if [ "$stop" -eq 1 ]; then
	adb_device shell am force-stop "$PKG"
	echo "Stopped $PKG on $device."
	exit 0
fi

abi=$(adb_device shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')
if [ -z "$abi" ]; then
	echo "android-speech-frontend: could not read the device ABI" >&2
	exit 1
fi

if [ "$install" -eq 1 ]; then
	if [ ! -f "$apk" ]; then
		echo "android-speech-frontend: APK not found: $apk" >&2
		echo "build it with: ./build-android-apk.sh --gui sdl3 --abi arm64-v8a" >&2
		exit 1
	fi
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

if [ -z "$phone_ip" ]; then
	for iface in tailscale0 wlan0; do
		phone_ip=$(adb_device shell ip -4 -o addr show "$iface" 2>/dev/null |
			sed -n 's/.* inet \([0-9.]*\)\/.*/\1/p' | head -n 1 | tr -d '\r')
		if [ -n "$phone_ip" ]; then
			phone_iface=$iface
			break
		fi
	done
	if [ -z "$phone_ip" ]; then
		echo "android-speech-frontend: no tailscale0 or wlan0 IPv4 address found" >&2
		exit 1
	fi
	if [ "$phone_iface" = wlan0 ]; then
		echo "note: Tailscale was not detected; using Wi-Fi address $phone_ip" >&2
	fi
fi

echo "Launching Android speech export on $phone_ip:$port ..."
adb_device shell am force-stop "$PKG"
adb_device shell am start -n "$PKG/.InfernodeSDLActivity" \
	--es io.infernode.extra.MODE speech-export \
	--ei io.infernode.extra.SPEECH_PORT "$port" >/dev/null

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

cat <<EOF
Android speech frontend is ready.
  device: $device ($abi)
  address: tcp!$phone_ip!$port
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
