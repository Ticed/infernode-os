#!/bin/sh
#
# Verify that every top-level test source is named exactly once in TARG.
#
# A source outside TARG is never built or run. Duplicate TARG entries are
# rejected because they make the build list ambiguous and hide bookkeeping
# mistakes.
#
# Exit codes:
#   0  — all top-level tests are named once
#   1  — missing or duplicate TARG entries
#   2  — setup or input error
#
set -u

# comm(1) requires both inputs in the same collation order, and sort(1)
# collates by locale, so a script that sorts under one locale and compares
# under another reports entries that are present as missing.  Pin both ends
# to C.
LC_ALL=C
export LC_ALL

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." 2>/dev/null && pwd) || {
	echo "verify-test-targs: SETUP ERROR: cannot locate repository root" >&2
	exit 2
}
cd "$ROOT" || {
	echo "verify-test-targs: SETUP ERROR: cannot enter repository root" >&2
	exit 2
}

MKFILE=$ROOT/tests/mkfile
if [ ! -f "$MKFILE" ]; then
	echo "verify-test-targs: SETUP ERROR: tests/mkfile is missing" >&2
	exit 2
fi

if ! command -v awk >/dev/null 2>&1 || ! command -v sort >/dev/null 2>&1 ||
	! command -v comm >/dev/null 2>&1 || ! command -v mktemp >/dev/null 2>&1; then
	echo "verify-test-targs: SETUP ERROR: awk, sort, comm, and mktemp are required" >&2
	exit 2
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/verify-test-targs.XXXXXX") || {
	echo "verify-test-targs: SETUP ERROR: cannot create temporary directory" >&2
	exit 2
}
trap 'rm -rf "$tmp"' 0 1 2 3 15

# Extract only the first blank-line-terminated TARG block. Do not parse rule
# definitions below it: a rule name is not another TARG entry.
if ! awk '
BEGIN { in_targ = 0; found = 0 }
/^TARG[[:space:]]*=[[:space:]]*\\/ && !found {
	in_targ = 1
	found = 1
	next
}
in_targ && NF == 0 {
	in_targ = 0
	next
}
in_targ {
	line = $0
	sub(/^[[:space:]]*/, "", line)
	sub(/[[:space:]]*\\[[:space:]]*$/, "", line)
	if (line ~ /^[A-Za-z0-9_][A-Za-z0-9_]*[.]dis$/) {
		sub(/[.]dis$/, "", line)
		print line
	}
}
END {
	if (!found || in_targ)
		exit 1
}
' "$MKFILE" >"$tmp/targ"; then
	echo "verify-test-targs: SETUP ERROR: cannot parse first TARG block in tests/mkfile" >&2
	exit 2
fi

: >"$tmp/sources"
for source in "$ROOT"/tests/*_test.b; do
	[ -f "$source" ] || continue
	basename "$source" .b >>"$tmp/sources" || {
		echo "verify-test-targs: SETUP ERROR: cannot enumerate test sources" >&2
		exit 2
	}
done

if ! sort -u "$tmp/targ" >"$tmp/targ-unique" ||
	! sort -u "$tmp/sources" >"$tmp/sources-unique"; then
	echo "verify-test-targs: SETUP ERROR: cannot sort test target lists" >&2
	exit 2
fi

# Keep the original TARG list for duplicate detection. sort -u is used only
# for membership comparison, never for deciding whether TARG repeats a name.
duplicates=$(awk '{ count[$0]++ } END { for (name in count) if (count[name] > 1) print name }' \
	"$tmp/targ" | sort) || {
	echo "verify-test-targs: SETUP ERROR: cannot inspect TARG duplicates" >&2
	exit 2
}
missing=$(comm -23 "$tmp/sources-unique" "$tmp/targ-unique") || {
	echo "verify-test-targs: SETUP ERROR: cannot compare source and TARG lists" >&2
	exit 2
}

rc=0
if [ -n "$missing" ]; then
	echo "FAIL: tests/*_test.b missing from tests/mkfile TARG:" >&2
	printf '%s\n' "$missing" | sed 's/^/  /' >&2
	rc=1
fi
if [ -n "$duplicates" ]; then
	echo "FAIL: duplicate TARG entries:" >&2
	printf '%s\n' "$duplicates" | sed 's/^/  /' >&2
	rc=1
fi

if [ "$rc" -ne 0 ]; then
	exit "$rc"
fi

echo "OK: $(wc -l <"$tmp/sources-unique" | tr -d ' ') top-level tests named exactly once in tests/mkfile TARG"
exit 0
