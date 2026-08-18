#!/bin/sh
#
# tests/host/android_speech_preflight_test.sh
#
# Hermetic coverage of tools/android-speech-preflight.sh (INF-17): SDK/NDK
# discovery on a standard Android Studio layout, combined failure reporting,
# helper/model/playback/network misses, and local.properties writing.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/android-speech-preflight.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

PREFLIGHT="$ROOT/tools/android-speech-preflight.sh"
HOME_DIR="$TMP/home"
REPO="$TMP/repo"
SPEECH="$TMP/speech"

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

case "$(uname -s)" in
Darwin*)
	ndk_tag=darwin-x86_64
	host_tree=MacOSX/arm64
	;;
*)
	ndk_tag=linux-x86_64
	host_tree=Linux/amd64
	;;
esac

studio_sdk="$HOME_DIR/Library/Android/sdk"
studio_ndk="$studio_sdk/ndk/29.0.14206865"
clang="$studio_ndk/toolchains/llvm/prebuilt/$ndk_tag/bin/aarch64-linux-android24-clang"

install_studio_sdk()
{
	mkdir -p "$studio_sdk/platform-tools" \
		"$studio_ndk/toolchains/llvm/prebuilt/$ndk_tag/bin"
	: > "$studio_sdk/platform-tools/adb"
	chmod +x "$studio_sdk/platform-tools/adb"
	: > "$clang"
	chmod +x "$clang"
	_jbr="$HOME_DIR/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin"
	mkdir -p "$_jbr"
	: > "$_jbr/java"
	chmod +x "$_jbr/java"
}


install_host_tools()
{
	mkdir -p "$REPO/$host_tree/bin"
	: > "$REPO/$host_tree/bin/mk"
	: > "$REPO/$host_tree/bin/limbo"
	chmod +x "$REPO/$host_tree/bin/mk" "$REPO/$host_tree/bin/limbo"
}

install_helpers()
{
	mkdir -p "$SPEECH/bin" "$SPEECH/models/kokoro" "$SPEECH/models/parakeet"
	: > "$SPEECH/bin/kokoro-cli"
	: > "$SPEECH/bin/openwakeword-cli"
	: > "$SPEECH/bin/whisper-stream-cli"
	chmod +x "$SPEECH/bin/kokoro-cli" "$SPEECH/bin/openwakeword-cli" \
		"$SPEECH/bin/whisper-stream-cli"
	: > "$SPEECH/models/kokoro/kokoro-v1.0.onnx"
	: > "$SPEECH/models/kokoro/voices-v1.0.bin"
	: > "$SPEECH/models/ggml-base.en.bin"
}

run_preflight()
{
	# Isolate from the developer's real Android / speech install.
	env -u ANDROID_HOME -u ANDROID_SDK_ROOT -u ANDROID_NDK_HOME -u JAVA_HOME \
		-u ADB \
		HOME="$HOME_DIR" \
		ANDROID_PREFLIGHT_HOME="$HOME_DIR" \
		ANDROID_PREFLIGHT_ROOT="$REPO" \
		INFERNODE_SPEECH_HOME="$SPEECH" \
		ANDROID_PREFLIGHT_PLAYBACK_LIST="$TMP/playback.list" \
		PATH="/usr/bin:/bin" \
		"$@"
}

mkdir -p "$HOME_DIR" "$REPO/android-app" "$SPEECH"
: > "$TMP/playback.list"

# --- empty machine: every class of miss in one pass ----------------------
run_preflight "$PREFLIGHT" --build --speech \
	> "$TMP/empty.out" 2> "$TMP/empty.err" || empty_rc=$?
empty_rc=${empty_rc:-0}
check "empty machine fails" test "$empty_rc" -ne 0
check "empty machine reports Android SDK" \
	grep -q 'Android SDK' "$TMP/empty.err"
check "empty machine reports Android NDK" \
	grep -q 'Android NDK' "$TMP/empty.err"
check "empty machine reports host mk" \
	grep -q 'host Inferno toolchain (mk)' "$TMP/empty.err"
check "empty machine looks for bin/limbo, not bin/mk/limbo" \
	grep -q '/bin/limbo' "$TMP/empty.err"
check "empty machine does not nest limbo under mk" \
	awk 'BEGIN{bad=0} /\/bin\/mk\/limbo/{bad=1} END{exit bad}' "$TMP/empty.err"

check "empty machine reports host limbo" \
	grep -q 'host Inferno toolchain (limbo)' "$TMP/empty.err"
check "empty machine names the mk bootstrap" \
	grep -q './makemk.sh' "$TMP/empty.err"
check "empty machine reports helpers/models" \
	grep -q 'speech helpers/models' "$TMP/empty.err"
check "empty machine names the helper installer" \
	grep -q 'tools/install-speech-helpers.sh' "$TMP/empty.err"
check "empty machine reports playback" \
	grep -q 'playback device' "$TMP/empty.err"
check "empty machine reports network/adb" \
	grep -q 'adb' "$TMP/empty.err"
check "SDK miss lists the Studio path" \
	grep -q 'Library/Android/sdk' "$TMP/empty.err"
check "NDK miss lists the SDK ndk directory" \
	grep -q '/ndk' "$TMP/empty.err"

# --- standard Android Studio layout, no env vars -------------------------
install_studio_sdk
install_host_tools
install_helpers
echo 'Fake Speakers' > "$TMP/playback.list"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/adb" <<'EOF'
#!/bin/sh
if [ "$1" = devices ]; then
	echo 'List of devices attached'
	echo 'phone-one	device'
	exit 0
fi
case "$*" in
*' shell ip -4 -o addr show tailscale0')
	echo '42: tailscale0    inet 100.84.91.15/32 scope global tailscale0' ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/adb"

run_preflight PATH="$TMP/bin:/usr/bin:/bin" ADB="$TMP/bin/adb" \
	"$PREFLIGHT" --build --speech --write-local-properties \
	> "$TMP/ok.out" 2> "$TMP/ok.err" || ok_rc=$?
ok_rc=${ok_rc:-0}
check "Studio layout succeeds without ANDROID_*" test "$ok_rc" -eq 0
check "reports the Studio SDK path" \
	grep -q "using Android SDK at $studio_sdk" "$TMP/ok.out"
check "reports the Studio NDK path" \
	grep -q "using Android NDK at $studio_ndk" "$TMP/ok.out"
check "reports the host toolchain" \
	grep -q "using host toolchain at $REPO/$host_tree/bin" "$TMP/ok.out"
check "reports speech helpers" \
	grep -q "using speech helpers at $SPEECH" "$TMP/ok.out"
check "reports playback" \
	grep -q 'using playback device Fake Speakers' "$TMP/ok.out"
check "reports the phone address" \
	grep -q 'using phone address 100.84.91.15' "$TMP/ok.out"
check "writes android-app/local.properties" \
	grep -q "sdk.dir=$studio_sdk" "$REPO/android-app/local.properties"

# --- explicit ANDROID_NDK_HOME wins --------------------------------------
other_ndk="$TMP/other-ndk"
mkdir -p "$other_ndk/toolchains/llvm/prebuilt/$ndk_tag/bin"
: > "$other_ndk/toolchains/llvm/prebuilt/$ndk_tag/bin/aarch64-linux-android24-clang"
chmod +x "$other_ndk/toolchains/llvm/prebuilt/$ndk_tag/bin/aarch64-linux-android24-clang"

run_preflight PATH="$TMP/bin:/usr/bin:/bin" ADB="$TMP/bin/adb" \
	ANDROID_NDK_HOME="$other_ndk" \
	"$PREFLIGHT" --build \
	> "$TMP/ndkhome.out" 2> "$TMP/ndkhome.err" || ndkhome_rc=$?
ndkhome_rc=${ndkhome_rc:-0}
check "honors ANDROID_NDK_HOME" test "$ndkhome_rc" -eq 0
check "reports ANDROID_NDK_HOME as the source" \
	grep -q "using Android NDK at $other_ndk (\$ANDROID_NDK_HOME)" "$TMP/ndkhome.out"

# --- bad ANDROID_NDK_HOME is a hard error, not a silent fallback ---------
run_preflight PATH="$TMP/bin:/usr/bin:/bin" ADB="$TMP/bin/adb" \
	ANDROID_NDK_HOME="$TMP/missing-ndk" \
	"$PREFLIGHT" --build \
	> "$TMP/badndk.out" 2> "$TMP/badndk.err" || badndk_rc=$?
badndk_rc=${badndk_rc:-0}
check "rejects a bogus ANDROID_NDK_HOME" test "$badndk_rc" -ne 0
check "names the bogus ANDROID_NDK_HOME" \
	grep -q "$TMP/missing-ndk" "$TMP/badndk.err"
check "does not fall back when ANDROID_NDK_HOME is set" \
	grep -qv "using Android NDK at $studio_ndk" "$TMP/badndk.out"

# --- recipe documentation matches the search order -----------------------
check "recipe documents the Studio SDK path" \
	grep -q '~/Library/Android/sdk' "$ROOT/docs/SPEECH-REMOTE-AUDIO.md"
check "APK driver sources the preflight" \
	grep -q 'tools/android-speech-preflight.sh' "$ROOT/build-android-apk.sh"
check "frontend sources the preflight" \
	grep -q 'tools/android-speech-preflight.sh' "$ROOT/tools/android-speech-frontend.sh"
check "Gradle settings search the Studio SDK" \
	grep -q 'Library/Android/sdk' "$ROOT/android-app/settings.gradle.kts"

echo "android_speech_preflight_test: $pass passed, $fail failed"
test "$fail" -eq 0
