#!/bin/sh
#
# verify-dis-reproducible.sh — the tracked runtime tree must be exactly
# what the tracked source compiles to.
#
# dis/ is committed so a release runs without the user building anything.
# The cost of that is a tree which can drift from its source with nothing
# to say so: bytecode goes stale, a module gets compiled to the wrong
# path, a source is deleted and its binary is left behind, or a .dis is
# committed that no mkfile ever builds.  Every one of those has happened
# here.  This check makes all of them impossible to commit.
#
# It does NOT try to reason about where a .dis should go, which is what
# the wrong-target trap defeats.  It rebuilds the tree and compares.
# mk already knows every answer such reasoning would try to reconstruct.
#
# Why the tracked .dis are deleted first: mk compares mtimes, and a
# fresh `git checkout` stamps every file with the checkout time, so
# `mk install` concludes the tree is up to date and rebuilds nothing.
# The check would then pass without compiling a line.  Removing the
# output forces a real build.
#
# limbo output is deterministic and records the source path relative to
# $ROOT, so this is reproducible across machines and architectures —
# provided the build runs from the repository root.  It does not depend
# on the host OS or CPU.
#
# Exit codes:
#   0  — dis/ is exactly what the source compiles to
#   1  — drift; the differing paths are listed
#   2  — setup error (wrong directory, missing toolchain)
#
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
export ROOT
cd "$ROOT"

if [ ! -f mkconfig ] || [ ! -d dis ]; then
	echo "verify-dis-reproducible: run from an InferNode checkout" >&2
	exit 2
fi

if ! command -v mk >/dev/null 2>&1 || ! command -v limbo >/dev/null 2>&1; then
	echo "verify-dis-reproducible: mk and limbo must be on PATH" >&2
	echo "  build them first:  SYSTARG=\$(uname -s) ./makemk.sh" >&2
	echo "  then add:          \$ROOT/\$SYSHOST/\$OBJTYPE/bin" >&2
	exit 2
fi

# Every tree with a DISBIN under dis/.  appl/mpeg and appl/veltro are
# NOT in appl/mkfile's DIRS, so `cd appl && mk install` does not reach
# them; they are listed explicitly rather than left to be rediscovered.
DIRS="appl appl/mpeg appl/veltro tests"

echo "verify-dis-reproducible: regenerating dis/ from source"

git ls-files dis | grep '\.dis$' > "$ROOT/.dis-tracked.tmp"
while read -r f; do rm -f "$f"; done < "$ROOT/.dis-tracked.tmp"
rm -f "$ROOT/.dis-tracked.tmp"
find appl tests -name '*.dis' -exec rm -f {} +
find appl tests -name '*.sbl' -exec rm -f {} +

rc=0
for d in $DIRS; do
	if ! (cd "$d" && mk install) > "$ROOT/.dis-build-$$.log" 2>&1; then
		echo "verify-dis-reproducible: build failed in $d" >&2
		grep -E '\.b:[0-9]+:' "$ROOT/.dis-build-$$.log" | grep -v 'warning:' >&2 || true
		rc=2
	fi
	rm -f "$ROOT/.dis-build-$$.log"
done
[ "$rc" = 0 ] || exit "$rc"

drift=$(git status --porcelain dis | wc -l)
if [ "$drift" -ne 0 ]; then
	echo "" >&2
	echo "dis/ does not match what the source compiles to:" >&2
	echo "" >&2
	git status --porcelain dis | sed 's/^/    /' >&2
	echo "" >&2
	echo "  ' M path'  bytecode differs from its source — commit the rebuild" >&2
	echo "  ' D path'  nothing builds this — the source is missing, or the" >&2
	echo "             module is absent from its mkfile TARG" >&2
	echo "  '?? path'  built but untracked — git add it" >&2
	echo "" >&2
	echo "Rebuild with:  for d in $DIRS; do (cd \$d && mk install); done" >&2
	exit 1
fi

echo "OK: all $(git ls-files dis | grep -c '\.dis$') tracked .dis regenerate byte-identically from source"
