#!/bin/sh
# Combined prerequisite check for the Mac + Android speech recipe.
#
# Searches the locations a standard Android Studio install actually uses,
# then reports every missing prerequisite in one pass. Sourced by
# build-android-apk.sh and tools/android-speech-frontend.sh; also runnable
# on its own:
#
#   tools/android-speech-preflight.sh            # build + speech
#   tools/android-speech-preflight.sh --build    # SDK/NDK/host/java
#   tools/android-speech-preflight.sh --speech   # helpers/models/playback/network
#
# Override search roots in tests with ANDROID_PREFLIGHT_HOME and
# ANDROID_PREFLIGHT_ROOT. ANDROID_HOME / ANDROID_SDK_ROOT / ANDROID_NDK_HOME
# still win when they are set, and a bad explicit value is a hard error.

android_preflight_errors=
android_preflight_sdk=
android_preflight_sdk_how=
android_preflight_ndk=
android_preflight_ndk_how=
android_preflight_host_bin=
android_preflight_java=
android_preflight_java_how=
android_preflight_adb=
android_preflight_home=
android_preflight_root=

android_preflight_init()
{
	android_preflight_home=${ANDROID_PREFLIGHT_HOME:-$HOME}
	if [ -n "${ANDROID_PREFLIGHT_ROOT:-}" ]; then
		android_preflight_root=$ANDROID_PREFLIGHT_ROOT
	elif [ -n "${ROOT:-}" ]; then
		android_preflight_root=$ROOT
	else
		echo "android-speech-preflight: set ROOT or ANDROID_PREFLIGHT_ROOT" >&2
		return 1
	fi
	android_preflight_errors=
	android_preflight_sdk=
	android_preflight_sdk_how=
	android_preflight_ndk=
	android_preflight_ndk_how=
	android_preflight_host_bin=
	android_preflight_java=
	android_preflight_java_how=
	android_preflight_adb=
}

android_preflight_add_error()
{
	android_preflight_errors="${android_preflight_errors}
* $1
    looked in: $2
    fix: $3"
}


android_preflight_ndk_host_tag()
{
	case "$(uname -s)" in
	Darwin*) printf '%s\n' darwin-x86_64 ;;
	Linux*) printf '%s\n' linux-x86_64 ;;
	*) printf '%s\n' linux-x86_64 ;;
	esac
}

android_preflight_ndk_usable()
{
	_ndk=$1
	_tag=$(android_preflight_ndk_host_tag)
	[ -x "$_ndk/toolchains/llvm/prebuilt/$_tag/bin/aarch64-linux-android24-clang" ]
}

android_preflight_sdk_usable()
{
	_sdk=$1
	[ -d "$_sdk" ] || return 1
	[ -d "$_sdk/platform-tools" ] || [ -d "$_sdk/build-tools" ] || \
		[ -d "$_sdk/platforms" ] || [ -d "$_sdk/ndk" ]
}

# Newest usable NDK r29 under $1/ndk. Empty if none.
android_preflight_best_ndk_under()
{
	_ndkroot=$1/ndk
	[ -d "$_ndkroot" ] || return 0
	_cands=
	for _d in "$_ndkroot"/*; do
		[ -d "$_d" ] || continue
		android_preflight_ndk_usable "$_d" || continue
		_base=${_d##*/}
		case "$_base" in
		29.*|android-ndk-r29)
			_cands="${_cands}${_d}
"
			;;
		esac
	done
	[ -n "$_cands" ] || return 0
	printf '%s' "$_cands" | sort -V | tail -n 1
}

android_preflight_studio_sdk()
{
	printf '%s\n' "$android_preflight_home/Library/Android/sdk"
}

android_preflight_legacy_sdk()
{
	printf '%s\n' "$android_preflight_home/Android/Sdk"
}

android_preflight_find_sdk()
{
	android_preflight_sdk=
	android_preflight_sdk_how=
	if [ -n "${ANDROID_HOME:-}" ]; then
		if android_preflight_sdk_usable "$ANDROID_HOME"; then
			android_preflight_sdk=$ANDROID_HOME
			android_preflight_sdk_how='$ANDROID_HOME'
			return 0
		fi
		return 0
	fi
	if [ -n "${ANDROID_SDK_ROOT:-}" ]; then
		if android_preflight_sdk_usable "$ANDROID_SDK_ROOT"; then
			android_preflight_sdk=$ANDROID_SDK_ROOT
			android_preflight_sdk_how='$ANDROID_SDK_ROOT'
			return 0
		fi
		return 0
	fi
	_studio=$(android_preflight_studio_sdk)
	if android_preflight_sdk_usable "$_studio"; then
		android_preflight_sdk=$_studio
		android_preflight_sdk_how='macOS Android Studio default (~/Library/Android/sdk)'
		return 0
	fi
	_legacy=$(android_preflight_legacy_sdk)
	if android_preflight_sdk_usable "$_legacy"; then
		android_preflight_sdk=$_legacy
		android_preflight_sdk_how='legacy Android SDK default (~/Android/Sdk)'
		return 0
	fi
}

android_preflight_sdk_looked_in()
{
	printf '%s' '$ANDROID_HOME, $ANDROID_SDK_ROOT, '"$(android_preflight_studio_sdk)"', '"$(android_preflight_legacy_sdk)"
}

android_preflight_check_sdk()
{
	android_preflight_find_sdk
	if [ -n "${ANDROID_HOME:-}" ] && [ -z "$android_preflight_sdk" ]; then
		android_preflight_add_error \
			"Android SDK (ANDROID_HOME is set but unusable)" \
			"$ANDROID_HOME" \
			"point ANDROID_HOME at a real SDK, or unset it and install Android Studio"
		return 0
	fi
	if [ -n "${ANDROID_SDK_ROOT:-}" ] && [ -z "${ANDROID_HOME:-}" ] && [ -z "$android_preflight_sdk" ]; then
		android_preflight_add_error \
			"Android SDK (ANDROID_SDK_ROOT is set but unusable)" \
			"$ANDROID_SDK_ROOT" \
			"point ANDROID_SDK_ROOT at a real SDK, or unset it and install Android Studio"
		return 0
	fi
	if [ -z "$android_preflight_sdk" ]; then
		android_preflight_add_error \
			"Android SDK" \
			"$(android_preflight_sdk_looked_in)" \
			"install Android Studio (SDK Manager), or set ANDROID_HOME"
		return 0
	fi
	echo "preflight: using Android SDK at $android_preflight_sdk ($android_preflight_sdk_how)"
}

android_preflight_find_ndk()
{
	android_preflight_ndk=
	android_preflight_ndk_how=
	if [ -n "${ANDROID_NDK_HOME:-}" ]; then
		if android_preflight_ndk_usable "$ANDROID_NDK_HOME"; then
			android_preflight_ndk=$ANDROID_NDK_HOME
			android_preflight_ndk_how='$ANDROID_NDK_HOME'
		fi
		return 0
	fi
	if [ -z "$android_preflight_sdk" ]; then
		android_preflight_find_sdk
	fi
	if [ -n "$android_preflight_sdk" ]; then
		_best=$(android_preflight_best_ndk_under "$android_preflight_sdk")
		if [ -n "$_best" ]; then
			android_preflight_ndk=$_best
			android_preflight_ndk_how="under SDK ndk/$(basename "$_best")"
			return 0
		fi
	fi
	_legacy_ndk=$(android_preflight_legacy_sdk)/ndk/android-ndk-r29
	if android_preflight_ndk_usable "$_legacy_ndk"; then
		android_preflight_ndk=$_legacy_ndk
		android_preflight_ndk_how='legacy default (~/Android/Sdk/ndk/android-ndk-r29)'
	fi
}

android_preflight_ndk_looked_in()
{
	_sdk=${android_preflight_sdk:-$(android_preflight_studio_sdk)}
	printf '%s' '$ANDROID_NDK_HOME, '"$_sdk"'/ndk/<r29>, '"$(android_preflight_legacy_sdk)"'/ndk/android-ndk-r29'
}

android_preflight_check_ndk()
{
	android_preflight_find_ndk
	if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -z "$android_preflight_ndk" ]; then
		android_preflight_add_error \
			"Android NDK (ANDROID_NDK_HOME is set but unusable)" \
			"$ANDROID_NDK_HOME (need toolchains/llvm/prebuilt/$(android_preflight_ndk_host_tag)/bin/aarch64-linux-android24-clang)" \
			"point ANDROID_NDK_HOME at NDK r29, or unset it so the SDK copy can be found"
		return 0
	fi
	if [ -z "$android_preflight_ndk" ]; then
		android_preflight_add_error \
			"Android NDK r29" \
			"$(android_preflight_ndk_looked_in)" \
			'sdkmanager --install "ndk;29.0.14206865"  (Android Studio → SDK Manager → NDK 29)'
		return 0
	fi
	echo "preflight: using Android NDK at $android_preflight_ndk ($android_preflight_ndk_how)"
}

android_preflight_host_candidates()
{
	printf '%s\n' \
		"$android_preflight_root/Linux/amd64/bin" \
		"$android_preflight_root/MacOSX/arm64/bin" \
		"$android_preflight_root/MacOSX/amd64/bin"
}

android_preflight_find_host_bin()
{
	android_preflight_host_bin=
	for _cand in \
		"$android_preflight_root/Linux/amd64/bin" \
		"$android_preflight_root/MacOSX/arm64/bin" \
		"$android_preflight_root/MacOSX/amd64/bin"
	do
		if [ -x "$_cand/mk" ]; then
			android_preflight_host_bin=$_cand
			return 0
		fi
	done
}

android_preflight_host_bootstrap()
{
	printf '%s' './makemk.sh && for d in lib9 libbio libmath libmp libsec; do (cd $d && mk nuke && mk install); done && (cd limbo && mk install)'
}

android_preflight_check_host()
{
	android_preflight_find_host_bin
	_looked="$android_preflight_root/{Linux/amd64,MacOSX/arm64,MacOSX/amd64}/bin"
	if [ -z "$android_preflight_host_bin" ]; then
		android_preflight_add_error \
			"host Inferno toolchain (mk)" \
			"$_looked/mk" \
			"$(android_preflight_host_bootstrap)"
		android_preflight_add_error \
			"host Inferno toolchain (limbo)" \
			"$_looked/limbo" \
			"$(android_preflight_host_bootstrap)"
		return 0
	fi
	if [ ! -x "$android_preflight_host_bin/limbo" ]; then
		android_preflight_add_error \
			"host Inferno toolchain (limbo)" \
			"$android_preflight_host_bin/limbo" \
			"$(android_preflight_host_bootstrap)"
		return 0
	fi
	echo "preflight: using host toolchain at $android_preflight_host_bin (mk, limbo)"
}

android_preflight_find_java()
{
	android_preflight_java=
	android_preflight_java_how=
	if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
		android_preflight_java=$JAVA_HOME
		android_preflight_java_how='$JAVA_HOME'
		return 0
	fi
	if command -v java >/dev/null 2>&1; then
		android_preflight_java=$(command -v java)
		android_preflight_java_how='java on PATH'
		return 0
	fi
	for _jbr in \
		"/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
		"$android_preflight_home/Applications/Android Studio.app/Contents/jbr/Contents/Home"
	do
		if [ -x "$_jbr/bin/java" ]; then
			android_preflight_java=$_jbr
			android_preflight_java_how='Android Studio JBR'
			return 0
		fi
	done
}

android_preflight_check_java()
{
	android_preflight_find_java
	if [ -z "$android_preflight_java" ]; then
		android_preflight_add_error \
			"JDK 17+ (needed for Gradle)" \
			'$JAVA_HOME/bin/java, java on PATH, /Applications/Android Studio.app/Contents/jbr' \
			'export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"  (or install a JDK 17+)'
		return 0
	fi
	echo "preflight: using Java at $android_preflight_java ($android_preflight_java_how)"
}

android_preflight_speech_home()
{
	printf '%s\n' "${INFERNODE_SPEECH_HOME:-$android_preflight_home/.local/share/infernode-speech}"
}

android_preflight_check_helpers()
{
	_prefix=$(android_preflight_speech_home)
	_missing=
	[ -x "$_prefix/bin/kokoro-cli" ] || _missing="${_missing} kokoro-cli"
	[ -x "$_prefix/bin/openwakeword-cli" ] || _missing="${_missing} openwakeword-cli"
	[ -f "$_prefix/models/kokoro/kokoro-v1.0.onnx" ] || _missing="${_missing} kokoro-v1.0.onnx"
	[ -f "$_prefix/models/kokoro/voices-v1.0.bin" ] || _missing="${_missing} voices-v1.0.bin"
	_stt=
	if [ -x "$_prefix/bin/parakeet-stream" ]; then
		for _m in "$_prefix/models/parakeet"/*.gguf; do
			if [ -f "$_m" ]; then
				_stt=parakeet
				break
			fi
		done
	fi
	if [ -z "$_stt" ] && [ -x "$_prefix/bin/whisper-stream-cli" ] && \
		[ -f "$_prefix/models/ggml-base.en.bin" ]; then
		_stt=whisper
	fi
	if [ -z "$_stt" ]; then
		_missing="${_missing} stt-model"
	fi
	if [ -n "$_missing" ]; then
		android_preflight_add_error \
			"speech helpers/models (${_missing# })" \
			"$_prefix/{bin,models}  (INFERNODE_SPEECH_HOME or ~/.local/share/infernode-speech)" \
			"tools/install-speech-helpers.sh"
		return 0
	fi
	echo "preflight: using speech helpers at $_prefix (stt=$_stt)"
}

android_preflight_playback_names()
{
	if [ -n "${ANDROID_PREFLIGHT_PLAYBACK_LIST:-}" ]; then
		if [ -f "$ANDROID_PREFLIGHT_PLAYBACK_LIST" ]; then
			cat "$ANDROID_PREFLIGHT_PLAYBACK_LIST"
		fi
		return 0
	fi
	if [ -n "${INFERNODE_AUDIO_OUT:-}" ]; then
		printf '%s\n' "$INFERNODE_AUDIO_OUT"
		return 0
	fi
	case "$(uname -s)" in
	Darwin)
		system_profiler SPAudioDataType -detailLevel mini 2>/dev/null | awk '

			/^        [^ ].*:$/ {
				name=$0
				sub(/^ +/, "", name)
				sub(/:$/, "", name)
			}
			/Default Output Device: Yes/ { print name; found=1; exit }
			/Output Channels: [1-9]/ { out=name }
			END { if (!found && out != "") print out }
		'

		;;
	Linux)
		if [ -e /dev/snd/pcmC0D0p ]; then
			printf '%s\n' /dev/snd/pcmC0D0p
		fi
		;;
	esac
}

android_preflight_check_playback()
{
	_names=$(android_preflight_playback_names)
	if [ -z "$_names" ]; then
		android_preflight_add_error \
			"playback device" \
			'INFERNODE_AUDIO_OUT, system audio outputs (system_profiler SPAudioDataType on macOS)' \
			"connect speakers or headphones, or: brew install --cask blackhole-2ch && export INFERNODE_AUDIO_OUT='BlackHole 2ch'"
		return 0
	fi
	_first=$(printf '%s\n' "$_names" | awk 'NF{print; exit}')
	echo "preflight: using playback device $_first"
}

android_preflight_find_adb()
{
	android_preflight_adb=
	if [ -n "${ADB:-}" ] && command -v "$ADB" >/dev/null 2>&1; then
		android_preflight_adb=$ADB
		return 0
	fi
	if command -v adb >/dev/null 2>&1; then
		android_preflight_adb=$(command -v adb)
		return 0
	fi
	if [ -z "$android_preflight_sdk" ]; then
		android_preflight_find_sdk
	fi
	if [ -n "$android_preflight_sdk" ] && [ -x "$android_preflight_sdk/platform-tools/adb" ]; then
		android_preflight_adb=$android_preflight_sdk/platform-tools/adb
	fi
}

android_preflight_check_network()
{
	_want_ip=${1:-}
	android_preflight_find_adb
	if [ -z "$android_preflight_adb" ]; then
		_sdk=${android_preflight_sdk:-$(android_preflight_studio_sdk)}
		android_preflight_add_error \
			"adb (needed to reach the phone)" \
			"\$ADB, adb on PATH, $_sdk/platform-tools/adb" \
			"install Android platform-tools, or use the copy under the resolved SDK"
		return 0
	fi
	if [ -n "$_want_ip" ]; then
		echo "preflight: using phone address $_want_ip (explicit)"
		return 0
	fi
	_devices=$("$android_preflight_adb" devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }') || _devices=
	set -- $_devices
	case "$#" in
	0)
		android_preflight_add_error \
			"Android device network (no authorized adb device)" \
			'adb devices' \
			"enable USB debugging, authorize this computer, or pass --device SERIAL"
		return 0
		;;
	1)
		_serial=$1
		;;
	*)
		android_preflight_add_error \
			"Android device network (multiple adb devices)" \
			"adb devices: $*" \
			"pass --device SERIAL so the phone address can be resolved"
		return 0
		;;
	esac
	_ip=
	_iface=
	for _iface in tailscale0 wlan0; do
		_ip=$("$android_preflight_adb" -s "$_serial" shell ip -4 -o addr show "$_iface" 2>/dev/null | \
			sed -n 's/.* inet \([0-9.]*\)\/.*/\1/p' | head -n 1 | tr -d '\r')
		if [ -n "$_ip" ]; then
			break
		fi
	done
	if [ -z "$_ip" ]; then
		android_preflight_add_error \
			"phone network reachability" \
			"adb -s $_serial shell ip -4 addr show tailscale0 / wlan0" \
			"join Tailscale on the phone, or the same Wi-Fi as this Mac, or pass --ip ADDRESS"
		return 0
	fi
	echo "preflight: using phone address $_ip ($_iface on $_serial)"
}

android_preflight_write_local_properties()
{
	_sdk=${1:-$android_preflight_sdk}
	[ -n "$_sdk" ] || return 0
	_dest=$android_preflight_root/android-app/local.properties
	[ -d "$android_preflight_root/android-app" ] || return 0
	_escaped=$(printf '%s' "$_sdk" | sed 's/\\/\\\\/g; s/:/\\:/g')
	if [ -f "$_dest" ]; then
		_cur=$(sed -n 's/^sdk\.dir=//p' "$_dest" | sed 's/\\:/:/g; s/\\\\/\\/g' | head -n 1)
		if [ -d "$_cur" ]; then
			echo "preflight: android-app/local.properties already has sdk.dir=$_cur"
			return 0
		fi
		_kept=$(grep -v '^sdk\.dir=' "$_dest" || true)
		{
			echo "# Generated by tools/android-speech-preflight.sh. Per-machine; not tracked."
			[ -n "$_kept" ] && printf '%s\n' "$_kept"
			echo "sdk.dir=$_escaped"
		} > "$_dest"
	else
		{
			echo "# Generated by tools/android-speech-preflight.sh. Per-machine; not tracked."
			echo "sdk.dir=$_escaped"
		} > "$_dest"
	fi
	echo "preflight: wrote sdk.dir=$_sdk to android-app/local.properties"
}

android_preflight_export()
{
	if [ -n "$android_preflight_sdk" ]; then
		ANDROID_HOME=$android_preflight_sdk
		ANDROID_SDK_ROOT=$android_preflight_sdk
		export ANDROID_HOME ANDROID_SDK_ROOT
		if [ -d "$android_preflight_sdk/platform-tools" ]; then
			PATH="$android_preflight_sdk/platform-tools:$PATH"
			export PATH
		fi
	fi
	if [ -n "$android_preflight_ndk" ]; then
		ANDROID_NDK_HOME=$android_preflight_ndk
		export ANDROID_NDK_HOME
	fi
	if [ -n "$android_preflight_host_bin" ]; then
		PATH="$android_preflight_host_bin:$PATH"
	fi
	# mkhost-MacOSX sets NDATE=ndate. Provide the POSIX wrapper when
	# the Inferno utils/ndate binary has not been built.
	if [ -x "$android_preflight_root/tools/ndate" ]; then
		PATH="$android_preflight_root/tools:$PATH"
	fi
	export PATH

	if [ -n "$android_preflight_java" ] && [ -d "$android_preflight_java" ] && \
		[ -x "$android_preflight_java/bin/java" ]; then
		JAVA_HOME=$android_preflight_java
		export JAVA_HOME
		PATH="$JAVA_HOME/bin:$PATH"
		export PATH
	fi
}

android_preflight_finish()
{
	if [ -n "$android_preflight_errors" ]; then
		echo "ERROR: missing Android speech prerequisites:" >&2
		printf '%s\n' "$android_preflight_errors" >&2
		echo >&2
		echo "All missing items are listed above. Fix them and re-run; do not export guessed paths." >&2
		return 1
	fi
	return 0
}

android_preflight_run_build()
{
	_need_java=${1:-1}
	android_preflight_check_sdk
	android_preflight_check_ndk
	android_preflight_check_host
	if [ "$_need_java" -eq 1 ]; then
		android_preflight_check_java
	fi
}

android_preflight_run_speech()
{
	_ip=${1:-}
	android_preflight_check_helpers
	android_preflight_check_playback
	android_preflight_check_network "$_ip"
}

android_speech_preflight_usage()
{
	cat <<'EOF'
usage: tools/android-speech-preflight.sh [--build] [--speech] [--ip ADDRESS] [--write-local-properties]

Check Android speech-recipe prerequisites together and print every miss.
--build   SDK, NDK r29, host mk/limbo, JDK
--speech  helpers/models, playback device, phone reachability
Default is both. Successful runs print the resolved locations.
EOF
}

android_speech_preflight_main()
{
	_do_build=0
	_do_speech=0
	_write_props=0
	_ip=
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--build) _do_build=1; shift ;;
		--speech) _do_speech=1; shift ;;
		--write-local-properties) _write_props=1; shift ;;
		--ip) _ip=$2; shift 2 ;;
		--ip=*) _ip=${1#*=}; shift ;;
		-h|--help) android_speech_preflight_usage; return 0 ;;
		*) echo "android-speech-preflight: unknown option: $1" >&2; android_speech_preflight_usage >&2; return 2 ;;
		esac
	done
	if [ "$_do_build" -eq 0 ] && [ "$_do_speech" -eq 0 ]; then
		_do_build=1
		_do_speech=1
	fi
	ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
	export ROOT
	android_preflight_init || return 1
	if [ "$_do_build" -eq 1 ]; then
		android_preflight_run_build 1
	fi
	if [ "$_do_speech" -eq 1 ]; then
		android_preflight_run_speech "$_ip"
	fi
	if [ "$_write_props" -eq 1 ]; then
		android_preflight_write_local_properties
	fi
	android_preflight_finish
}

case "${0##*/}" in
android-speech-preflight.sh)
	set -eu
	android_speech_preflight_main "$@"
	;;
esac
