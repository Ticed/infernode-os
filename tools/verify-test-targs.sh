#!/bin/sh
#
# verify-test-targs.sh — fail if a tests/*_test.b is missing from tests/mkfile TARG.
#
# A test that is tracked but not in TARG is never built by `mk install`,
# never installed to dis/tests/, and never discovered by the runner.
# One such file was found hiding three live bugs, and a later sweep found fifteen
# more. This guard is what stops the next one landing dark.
#
# Exit codes:
#   0  — every tests/*_test.b is named in TARG
#   1  — at least one orphan
#   2  — usage / setup error
#
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -f tests/mkfile ]; then
	echo "verify-test-targs: tests/mkfile missing" >&2
	exit 2
fi

built_file=$(mktemp)
present_file=$(mktemp)
trap 'rm -f "$built_file" "$present_file"' EXIT

# TARG is the first blank-line-terminated block starting at ^TARG.
# grep -o, not a greedy sed s//, so names like 9p_export_test stay intact.
sed -n '/^TARG/,/^$/p' tests/mkfile |
	grep -o '[A-Za-z0-9_]*_test\.dis' |
	sed 's/\.dis$//' |
	LC_ALL=C sort -u >"$built_file"
for f in tests/*_test.b; do
	[ -f "$f" ] || continue
	basename "$f" .b
done | LC_ALL=C sort -u >"$present_file"

orphans=$(comm -13 "$built_file" "$present_file")

if [ -n "$orphans" ]; then
	echo "FAIL: tests/*_test.b missing from tests/mkfile TARG:" >&2
	printf '%s\n' "$orphans" | sed 's/^/  /' >&2
	echo "" >&2
	echo "Add each as <name>.dis to the TARG list in tests/mkfile." >&2
	echo "A test that is not in TARG is never built or run." >&2
	exit 1
fi

n=$(wc -l <"$present_file" | tr -d ' ')
echo "OK: $n tests/*_test.b named in tests/mkfile TARG"
