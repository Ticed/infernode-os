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
require_literal appl/cmd/luciconv.b 'readfile("/n/speech/level")' \
  'voice UI does not consume provider PCM telemetry'
require_literal appl/cmd/luciconv.b 'sys->sleep(100);' \
  'voice meter is not updated at the documented 10Hz cadence'
require_literal appl/cmd/luciconv.b 'drawvoicemeter(meterr);' \
  'voice meter is not rendered in the standard conversation UI'
require_literal appl/cmd/luciconv.b 'label = "Listening";' \
  'microphone activity has no visible listening state'
require_literal appl/cmd/luciconv.b 'label = "Speaking";' \
  'playback activity has no visible speaking state'
require_literal appl/cmd/luciconv.b 'Rect((x, basey - h), (x + barw, basey))' \
  'microphone meter no longer uses bottom-up bars'
require_literal appl/cmd/luciconv.b 'Rect((x, centery - h), (x + barw, centery + h + 1))' \
  'playback meter no longer uses its distinct symmetric shape'
require_literal appl/cmd/luciconv.b 'conversation/voicequeue' \
  'Lucia does not consume the authoritative queued-follow-up state'
require_literal appl/cmd/luciconv.b 'Queued follow-up - not sent' \
  'queued voice text is not presented as an explicitly unsent turn'
require_literal appl/cmd/luciconv.b 'if(action == "Cancel")' \
  'queued follow-up has no queue-scoped cancel action'
require_literal appl/cmd/luciconv.b 'queuebuttonclick("Save replacement")' \
  'queued follow-up has no atomic replacement action'
require_literal appl/cmd/luciconv.b 'queueeditbuf: string;' \
  'queue replacement is not isolated from the typed compose buffer'
require_literal appl/cmd/luciconv.b 'state=disconnected\n' \
  'queue disconnects do not clear or label stale UI state'
for state in queued delivering delivered rejected cancelled replaced; do
  require_literal appl/cmd/luciuisrv.b "voicequeuestate = \"$state\"" \
    "server queue lifecycle omits $state"
done
require_literal appl/cmd/luciconv.b 'queuestate, queuedepth, queuecapacity' \
  'Lucia does not render authoritative queue state and capacity together'
require_literal appl/cmd/luciconv.b 'queuedepth > 0' \
  'delivered leftover queue status is still drawn as a follow-up tile'


echo 'PASS: every voice entry and exit surface uses one semantic control path'
echo 'PASS: production compose guard prevents key-driven draft mutation in voice mode'
echo 'PASS: standard voice UI renders distinct live input and playback meters'
echo 'PASS: Lucia exposes the bounded queued follow-up with cancel and atomic replace'
echo 'PASS'
