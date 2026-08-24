#!/bin/bash
#
# verify-dis-paths.sh — fail-fast guard against the "wrong .dis target" bug
# that cost us a full session of theme-propagation debugging.
#
# What happened: I was compiling lucifer-side modules with
#     limbo -o dis/cmd/lucictx.dis appl/cmd/lucictx.b
# but lucifer loads them via
#     LuciCtx: module { PATH: con "/dis/lucictx.dis"; ...}
# i.e. /dis/lucictx.dis (without cmd/).  Old stale .dis files at the
# correct path silently kept running while every "rebuilt" file landed
# in a parallel directory emu never read from.
#
# This script verifies that for every Limbo source file that contains a
# `PATH: con "/dis/...` declaration for the module it IMPLEMENTS, the
# corresponding compiled .dis exists at that path AND is at least as
# new as the source.
#
# Coverage: every directory that installs .dis files, i.e. every .b
# source under appl/ and tests/.  The set is derived from the source
# tree itself (find), NOT from a hardcoded directory list: a hardcoded
# list is this same bug one directory later.  Parsing the mkfiles
# instead would re-implement mk's recursive DIRS/include logic badly;
# the whole-tree scan is a strict superset of the mkfile-derived set,
# and sources that legitimately carry no inline PATH constant (their
# load path lives in module/*.m; mk's TARG governs their target) are
# counted and skipped explicitly, not failed.
#
# Runs in well under a second (single awk pass over the tree; stat is
# only spawned for the few sources that declare a PATH).  Pre-commit
# hook candidate; also wired into CI (see .github/workflows/).
#
# Exit codes:
#   0  — all sources have a fresh, correctly-placed .dis
#   1  — at least one mismatch; details printed to stderr
#   2  — usage / setup error
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
checked=0
skipped=0

# stat(1) is the classic cross-platform divergence:
#   macOS / BSD:  stat -f %m FILE   → mtime as epoch seconds
#   GNU / Linux:  stat -c %Y FILE   → mtime as epoch seconds
# Picking the wrong one prints filesystem-info text starting with
# "File:", which the (( … )) arithmetic later treated as an unset
# variable name and crashed CI.  Detect once and stash a function.
if stat -c %Y "$0" >/dev/null 2>&1; then
	mtime() { stat -c %Y "$1"; }
else
	mtime() { stat -f %m "$1"; }
fi

# scan_module_paths — one awk process over ALL sources.
# Same matching rules as tools/compile-limbo.sh (kept in sync): find
# `implement Foo;`, then scan forward for `Foo: module {` ...
# `PATH: con "/dis/..."` ... `}`.  The PATH of the module the file
# IMPLEMENTS, not the first PATH it mentions — files commonly cite the
# PATHs of modules they LOAD (cowfs, etc.) before their own interface.
#
# Input:  the .b sources as file arguments.
# Output: "<source>\t<PATH-constant>" per source that declares one,
#         plus a final "#skipped <n>" line for sources that do not.
scan_module_paths() {
	awk '
		function reset() {
			impl = ""; in_mod = 0; done = 0
		}
		FILENAME != prev {
			if (prev != "" && !done)
				noskipped++
			prev = FILENAME
			reset()
		}
		!done && /^implement[[:space:]]+[A-Za-z][A-Za-z0-9_]*[[:space:]]*;/ {
			match($0, /[A-Za-z][A-Za-z0-9_]*[[:space:]]*;/)
			impl = substr($0, RSTART, RLENGTH)
			sub(/[[:space:]]*;.*$/, "", impl)
		}
		!done && impl != "" && $0 ~ ("^" impl "[[:space:]]*:[[:space:]]*module") {
			in_mod = 1
			next
		}
		in_mod && !done && /PATH[[:space:]]*:[[:space:]]*con[[:space:]]*"\/dis\// {
			match($0, /"\/dis\/[^"]+"/)
			if (RSTART > 0) {
				p = substr($0, RSTART+1, RLENGTH-2)
				print FILENAME "\t" p
				done = 1
			}
		}
		in_mod && /^[[:space:]]*}/ {
			in_mod = 0
		}
		END {
			if (prev != "" && !done)
				noskipped++
			print "#skipped " noskipped + 0
		}
	' "$@"
}

# Every tree that installs .dis files: appl/ (via appl/*/mkfiles) and
# tests/ (via tests/mkfile).  find-derived so a new directory is
# covered the moment it exists.  bash 3.2 (macOS /bin/bash) has no
# mapfile, so build arrays with read loops.
SOURCES=()
while IFS= read -r -d '' src; do
	SOURCES+=("$src")
done < <(find appl tests -name '*.b' -type f -print0 | sort -z)

if (( ${#SOURCES[@]} == 0 )); then
	echo "verify-dis-paths: no .b sources found — run from the repo root" >&2
	exit 2
fi

ROWS=()
while IFS= read -r row; do
	ROWS+=("$row")
done < <(scan_module_paths "${SOURCES[@]}")

for row in "${ROWS[@]}"; do
	if [[ "$row" == \#skipped* ]]; then
		skipped="${row#\#skipped }"
		continue
	fi
	src="${row%%$'\t'*}"
	disrel="${row#*$'\t'}"

	# Strip leading slash and prefix with the source-tree root.
	dispath="${disrel#/}"
	if [[ ! -f "$dispath" ]]; then
		echo "FAIL: $src declares PATH=$disrel but $dispath is missing" >&2
		fail=1
		continue
	fi

	src_t=$(mtime "$src")
	dis_t=$(mtime "$dispath")

	if (( src_t > dis_t )); then
		echo "FAIL: $src is newer than $dispath (recompile needed)" >&2
		fail=1
		continue
	fi
	checked=$((checked + 1))
done

if (( fail )); then
	echo "" >&2
	echo "$checked sources checked, $skipped skipped (no inline PATH); FAILURES above." >&2
	echo "Recompile with: tools/compile-limbo.sh <source.b>  (do NOT pick an -o path by hand)" >&2
	echo "(do NOT default to dis/cmd/X.dis — read the module's PATH constant)" >&2
	exit 1
fi

echo "OK: $checked sources have fresh .dis at their declared PATH" \
	"($skipped skipped: no inline PATH constant, mk TARG governs those)"
