#!/usr/bin/env bash
set -euo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/parakeet-turn-gate.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

${CXX:-c++} -std=c++11 -Wall -Wextra -Werror \
  -I"$ROOT" \
  "$ROOT/tests/host/parakeet_turn_gate_test.cpp" \
  -o "$tmp/parakeet_turn_gate_test"

"$tmp/parakeet_turn_gate_test"
