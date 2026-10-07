#!/bin/sh
#
# xenith_acme_files_test.sh — the window files and ctl messages Xenith
# takes from canonical Acme: xdata, errors, ctl dirty, ctl menu/nomenu.
#
# This runs Xenith under the SDL dummy driver and drives
# tests/inferno/xenith_acme_files_test.sh against /mnt/xenith.
# Needs the SDL GUI emulator: SKIP (77) on a headless build.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "xenith_acme_files_test: SKIP (no emu)"; exit 77; }
if command -v nm >/dev/null 2>&1; then
    syms=$(nm "$EMU" 2>/dev/null)
    if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
        echo "xenith_acme_files_test: SKIP (headless emulator)"; exit 77
    fi
fi
[ -f "$ROOT/dis/xenith.dis" ] || { echo "xenith_acme_files_test: SKIP (Xenith not built)"; exit 77; }

# Xenith forks its namespace, so only commands it runs itself see
# /mnt/xenith. Hand it a dump file whose one external-command entry
# ("e", re-run on load as Acme does) runs the test inside Xenith and
# reports on the emulator's own console.
dir=$(mktemp -d "$ROOT/.xenith_acme_files.XXXXXX")
trap 'rm -rf "$dir"' EXIT
name=${dir##*/}
{
    echo /
    echo
    echo
    printf '%11d \n' 0
    printf 'e%11d %11d %11d %11d %11d \n' 0 0 0 0 0
    echo
    echo /
    echo "sh /$name/run"
} > "$dir/dump"
cat > "$dir/run" <<'END'
sh /tests/inferno/xenith_acme_files_test.sh >'#c/cons' >[2=1]
echo halt >'#c/sysctl'
END

out=$(SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -c0 -g800x600 -r"$ROOT" /dis/sh.dis -c "
load std
xenith -l /$name/dump" 2>&1)

printf '%s\n' "$out" | grep -E '^(PASS|FAIL|ALL PASS)'
if printf '%s\n' "$out" | grep -q '^ALL PASS'; then
    exit 0
fi
echo "FAIL: xenith_acme_files_test"
printf '%s\n' "$out" | grep -vE '^(PASS|FAIL)' | sed 's/^/    /'
exit 1
