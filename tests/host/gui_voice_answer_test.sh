#!/usr/bin/env bash
set -euo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
export ROOT
exec python3 "$ROOT/tests/host/gui_voice_answer_test.py"