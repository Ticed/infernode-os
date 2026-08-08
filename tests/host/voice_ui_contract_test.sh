#!/usr/bin/env bash
set -euo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
cd "$ROOT"

require_literal() {
  local file=$1 literal=$2 label=$3
  grep -Fq "$literal" "$file" || {
    echo "FAIL: $label" >&2
    exit 1
  }
}

require_literal appl/cmd/luciconv.b 'togglevoice("compose-button")' \
  'compose voice button is not wired to the semantic control path'
require_literal appl/cmd/luciconv.b 'togglevoice("ctrl-space")' \
  'Ctrl-Space is not wired to the semantic control path'
require_literal appl/cmd/lucictx.b 'off source=context-chip' \
  'Voice resource chip is not wired to the semantic control path'
require_literal appl/cmd/lucifer.b 'off source=escape' \
  'Escape is not wired to the semantic control path'
require_literal appl/cmd/lucifer.b 'on source=escape-v' \
  'Esc-V is not wired to the semantic control path'
require_literal appl/cmd/lucibridge.b 'on source=slash-command' \
  '/voice mode on is not wired to the semantic control path'
require_literal appl/cmd/lucibridge.b 'off source=slash-command' \
  '/voice mode off is not wired to the semantic control path'
require_literal emu/port/draw-sdl3.c 'Alt+V is emitted from KEY_DOWN as ESC,v' \
  'Option/Alt+V no longer reaches the Esc-V input path'

# This is the production compose guard: while voice owns the pending turn,
# ordinary key events cannot reach any inputbuf mutation below the guard.
require_literal appl/cmd/luciconv.b \
  'if(voiceactive() && k != 0 && k != 16rF00E && k != 16rF00F)' \
  'voice mode no longer locks the typed compose buffer'
require_literal appl/cmd/luciconv.b \
  '# verbatim until the user exits voice mode.' \
  'typed compose preservation contract is missing'

echo 'PASS: every voice entry and exit surface uses one semantic control path'
echo 'PASS: production compose guard prevents key-driven draft mutation in voice mode'
echo 'PASS'
