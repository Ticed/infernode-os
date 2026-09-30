#!/bin/sh
#
# wm/sam end to end through the GUI: boot a headless wm/wm, start sam
# on a file, and drive it with synthetic input through /chan/uitest —
# type a command in the command window, double-click a word in the file
# window, change it, write.  Checks the file sam wrote, not pixels.
#
# Covers what the protocol-level tests/sam_test.b cannot: that samterm
# pumps keyboard and mouse into Tk, that command output leaves the
# command window's typing point at its end, that a double click reaches
# the engine, and that host changes redraw the window.
#
# Needs a built emu and dis/ (mk install in appl); skips without them.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/wm/sam.dis" ] && [ -f "$ROOT/dis/wm/wm.dis" ] || {
    echo "SKIP: dis/wm not built"; exit 77; }

T=tmp/samgui_test.$$
DIR="$ROOT/$T"
mkdir -p "$DIR"
trap 'rm -rf "$DIR"' EXIT

printf 'The quick brown fox\njumps over\nthe lazy dog.\n' > "$DIR/fox.txt"

# Windows: the command window at the top, the file window below it; the
# third line of the file is at y=182, "lazy" at x=60.  A press with
# button bit 8 (257) is how the pointer device reports a double click.
cat > "$DIR/drive.sh" <<EOF
load std
wm/wm wm/sam /$T/fox.txt &
sleep 5
fn click { echo ptr \$1 \$2 1 > /chan/uitest; echo ptr \$1 \$2 0 > /chan/uitest }
fn type { for c in \$* { echo key \$c > /chan/uitest } }
click 300 120
sleep 1
type 44 115 47 111 47 48 47 103 10
sleep 1
click 60 182
sleep 1
click 60 182; echo ptr 60 182 257 > /chan/uitest; echo ptr 60 182 0 > /chan/uitest
sleep 1
click 300 120
sleep 1
type 99 47 115 108 101 101 112 121 47 10
sleep 1
type 119 10
sleep 2
echo R_DONE
EOF

LOG="$DIR/log"
(cd "$DIR" && SDL_VIDEODRIVER=dummy exec "$EMU" -c1 -pheap=512m -pmain=512m -pimage=512m \
    -g1024x768 -r"$ROOT" /dis/sh.dis "/$T/drive.sh" </dev/null >"$LOG" 2>&1) &
PID=$!
i=0
while [ $i -lt 60 ] && ! grep -q R_DONE "$LOG" 2>/dev/null; do
    sleep 1
    i=$((i+1))
done
kill $PID 2>/dev/null
wait $PID 2>/dev/null

if ! grep -q R_DONE "$LOG"; then
    echo "FAIL: driver did not finish"
    cat "$LOG"
    exit 1
fi

want='The quick br0wn f0x
jumps 0ver
the sleepy d0g.'
got=$(cat "$DIR/fox.txt")
if [ "$got" != "$want" ]; then
    echo "FAIL: file after editing through the GUI"
    echo "--- want"; echo "$want"
    echo "--- got"; echo "$got"
    echo "--- emu log"; cat "$LOG"
    exit 1
fi
echo "PASS: sam edits through the GUI"
exit 0
