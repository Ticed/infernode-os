#!/bin/sh
# Verify the SDL3 build script stamps include/version.h without destroying it.
#
# Two properties, both of which the previous mechanism got wrong:
#   - a failed build restores what was there, not what git has, so an
#     in-progress edit to version.h survives;
#   - the stamp anchors on the unstamped form, so a second run cannot stamp
#     an already-stamped string.
#
# The build is expected to fail here: mk is not on PATH. That is the point —
# it exercises the EXIT trap, which is the path that used to lose the edit.

set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
VERSION_H="$ROOT/include/version.h"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/macos-version-stamp.XXXXXX")

ORIGINAL=$TMP/version.h.original
cp "$VERSION_H" "$ORIGINAL"
cleanup() {
	cp "$ORIGINAL" "$VERSION_H"
	rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM

# Satisfy the SDL3 probe so this test does not depend on SDL3 being installed.
cat > "$TMP/pkg-config" <<'STUB'
#!/bin/sh
case "$1" in
--exists) exit 0 ;;
--modversion) echo "0.0.0-stub" ;;
esac
exit 0
STUB
chmod +x "$TMP/pkg-config"

# Stand in for a developer's in-progress edit.
sed 's|InferNode 0\.1 (|InferNode 0.1 (LOCAL EDIT |' "$ORIGINAL" > "$VERSION_H"
cp "$VERSION_H" "$TMP/version.h.edited"

run_build() {
	if PATH="$TMP:$PATH" "$ROOT/build-macos-sdl3.sh" >"$TMP/out" 2>&1; then
		echo "build unexpectedly succeeded; this test needs it to fail after stamping" >&2
		exit 1
	fi
}

run_build
if ! cmp -s "$VERSION_H" "$TMP/version.h.edited"; then
	echo "version.h was not restored to the edited content" >&2
	echo "expected:"; sed 's/^/  /' "$TMP/version.h.edited" >&2
	echo "got:";      sed 's/^/  /' "$VERSION_H" >&2
	exit 1
fi

# A second run must leave it identical again, not doubly stamped.
run_build
if ! cmp -s "$VERSION_H" "$TMP/version.h.edited"; then
	echo "version.h differs after a second run" >&2
	exit 1
fi
if grep -c "build " "$VERSION_H" | grep -qv '^0$'; then
	echo "a build stamp was left behind in version.h" >&2
	sed 's/^/  /' "$VERSION_H" >&2
	exit 1
fi

echo "macos_version_stamp: PASS"
