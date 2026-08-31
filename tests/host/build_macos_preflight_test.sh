#!/bin/sh
# Verify the macOS build scripts refuse to start when a native build tool is
# absent, and name the bootstrap in the message.
#
# Both tools matter. makemk.sh builds mk alone, so mk present and limbo absent
# is the state a half-finished bootstrap leaves behind, and it is the case the
# build used to hit as a bare "limbo: command not found" minutes in.

set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/build-macos-preflight.XXXXXX")

# Both build scripts prepend "$ROOT/MacOSX/arm64/bin" to PATH before the
# preflight check, so an empty PATH is not enough to hide the tools on a
# machine where they are actually built — the preflight would never fire and
# the test would fail on exactly the platform it is written for. Move the
# native tools aside for the duration so the script's own PATH line finds
# nothing either, and restore them on the way out.
BIN="$ROOT/MacOSX/arm64/bin"
STASH="$TMP/bin-stash"
mkdir -p "$STASH"
stash_native_tools() {
	for t in mk limbo; do
		if [ -e "$BIN/$t" ]; then mv "$BIN/$t" "$STASH/$t"; fi
	done
}
restore_native_tools() {
	for t in mk limbo; do
		if [ -e "$STASH/$t" ]; then mv "$STASH/$t" "$BIN/$t"; fi
	done
}
stash_native_tools
trap 'restore_native_tools; rm -rf "$TMP"' EXIT HUP INT TERM

# Keep dirname available while controlling which build tools are on PATH.
ln -s "$(command -v dirname)" "$TMP/dirname"

# The SDL3 script probes for the library before anything else. Satisfy that
# probe so this test isolates the build-tool preflight and does not depend on
# SDL3 being installed.
cat > "$TMP/pkg-config" <<'STUB'
#!/bin/sh
case "$1" in
--exists) exit 0 ;;
--modversion) echo "0.0.0-stub" ;;
esac
exit 0
STUB
chmod +x "$TMP/pkg-config"

expect_refusal() {
	script=$1
	missing=$2
	if output=$(env PATH="$TMP" "$ROOT/$script" 2>&1); then
		echo "$script: unexpectedly succeeded without $missing" >&2
		exit 1
	fi
	for want in \
		"required native build tool(s) not found: $missing" \
		"./makemk.sh" \
		"lib9 libbio libmp libsec libmath utils/iyacc limbo"; do
		if ! printf '%s\n' "$output" | grep -F "$want" >/dev/null; then
			echo "$script [$missing]: expected the message to contain: $want" >&2
			echo "got:" >&2
			printf '%s\n' "$output" | sed 's/^/  /' >&2
			exit 1
		fi
	done
}

for script in build-macos-headless.sh build-macos-sdl3.sh; do
	# Neither tool present.
	rm -f "$TMP/mk"
	expect_refusal "$script" "mk limbo"

	# mk present, limbo absent — the half-bootstrapped case.
	printf '#!/bin/sh\nexit 0\n' > "$TMP/mk"
	chmod +x "$TMP/mk"
	expect_refusal "$script" "limbo"
done

echo "build_macos_preflight: PASS"
