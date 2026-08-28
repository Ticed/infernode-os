#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/infernode-speech-setup.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

INSTALLER="$ROOT/tools/install-speech-helpers.sh"
SETUP="$ROOT/tools/speech-setup.sh"
FAKEBIN="$TMP/bin"
mkdir -p "$FAKEBIN"

cat >"$FAKEBIN/whisper-stream" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$FAKEBIN/whisper-stream"

make_python() {
  local home=$1
  mkdir -p "$home/venv/bin"
  cat >"$home/venv/bin/python" <<'SH'
#!/bin/sh
exit 0
SH
  chmod +x "$home/venv/bin/python"
}

make_wrapper() {
  local path=$1
  cat >"$path" <<'SH'
#!/bin/sh
exit 0
SH
  chmod +x "$path"
}

make_valid_whisper() {
  local home=$1
  mkdir -p "$home/bin" "$home/models/kokoro" "$home/models/openwakeword"
  make_python "$home"
  make_wrapper "$home/bin/kokoro-cli"
  make_wrapper "$home/bin/openwakeword-cli"
  make_wrapper "$home/bin/whisper-stream-cli"
  printf 'onnx model\n' >"$home/models/kokoro/kokoro-v1.0.onnx"
  printf 'voices\n' >"$home/models/kokoro/voices-v1.0.bin"
  printf 'wake model\n' >"$home/models/openwakeword/hey_jarvis_v0.1.onnx"
  printf 'whisper model with enough bytes\n' >"$home/models/ggml-base.en.bin"
  cat >"$home/speech.ctl" <<EOF
# Written by tools/install-speech-helpers.sh — applied by boot.sh.
engine kokoro
kokorobin $home/bin/kokoro-cli
wakebin $home/bin/openwakeword-cli
voice af_bella
wakeword hey jarvis
wakethreshold 0.5
duplex half
whisperstreambin $home/bin/whisper-stream-cli
whispermodel $home/models/ggml-base.en.bin
micmode helper
EOF
}

check_env() {
  local home=$1
  env -u PARAKEET_EOU_MODEL -u PARAKEET_ALLOW_UNVERIFIED_MODEL \
    PATH="$FAKEBIN:$PATH" INFERNODE_SPEECH_HOME="$home" \
    WHISPER_MODEL_MIN_BYTES=8 "$INSTALLER" --check
}

# A complete Whisper fallback installation is detected read-only. Running the
# check twice leaves both the control file and its contents unchanged.
whisper_home="$TMP/whisper"
make_valid_whisper "$whisper_home"
before=$(find "$whisper_home" -type f -print | sort | xargs shasum)
check_env "$whisper_home" >"$TMP/whisper-check-1"
check_env "$whisper_home" >"$TMP/whisper-check-2"
grep -q 'status: installed' "$TMP/whisper-check-1"
grep -q 'stack: whisper' "$TMP/whisper-check-1"
grep -q 'Kokoro model:' "$TMP/whisper-check-1"
grep -q 'Kokoro voices:' "$TMP/whisper-check-1"
grep -q 'Whisper model:' "$TMP/whisper-check-1"
grep -q 'Whisper binary:' "$TMP/whisper-check-1"
grep -q 'status: installed' "$TMP/whisper-check-2"
[ "$before" = "$(find "$whisper_home" -type f -print | sort | xargs shasum)" ]
INFERNODE_SPEECH_HOME="$whisper_home" PATH="$FAKEBIN:$PATH" \
  WHISPER_MODEL_MIN_BYTES=8 TMPDIR="$TMP" \
  "$ROOT/tools/speech-setup.sh" --check \
  --status-file "$TMP/existing.status" --cancel-file "$TMP/existing.cancel" >"$TMP/existing.out"
grep -q 'nothing was changed' "$TMP/existing.out" || grep -q 'installed and passed helper checks' "$TMP/existing.out"
[ "$before" = "$(find "$whisper_home" -type f -print | sort | xargs shasum)" ]

# A missing wake model is reported as incomplete and does not invoke curl or
# create any replacement files.
rm "$whisper_home/models/openwakeword/hey_jarvis_v0.1.onnx"
check_env "$whisper_home" >"$TMP/whisper-missing" || missing_rc=$?
missing_rc=${missing_rc:-0}
[ "$missing_rc" -ne 0 ]
grep -q 'hey-jarvis wake model is missing' "$TMP/whisper-missing"
[ ! -e "$whisper_home/models/openwakeword/hey_jarvis_v0.1.onnx" ]

# The Parakeet branch uses the manifest pins and its startup smoke test.
parakeet_home="$TMP/parakeet"
manifest="$TMP/parakeet.manifest"
model="$parakeet_home/models/parakeet/fixture.gguf"
mkdir -p "$(dirname "$model")"
printf 'parakeet fixture\n' >"$model"
model_size=$(wc -c <"$model" | tr -d ' ')
model_sha=$(shasum -a 256 "$model" | awk '{print $1}')
cat >"$manifest" <<EOF
PARAKEET_CPP_REPO_URL=https://example.invalid/parakeet.git
PARAKEET_CPP_COMMIT=1111111111111111111111111111111111111111
PARAKEET_MODEL_REPO=example/parakeet
PARAKEET_MODEL_REVISION=2222222222222222222222222222222222222222
PARAKEET_MODEL_FILE=source.nemo
PARAKEET_MODEL_SHA256=$model_sha
PARAKEET_MODEL_SIZE=$model_size
PARAKEET_GGUF_REPO=example/parakeet-gguf
PARAKEET_GGUF_REVISION=3333333333333333333333333333333333333333
PARAKEET_GGUF_FILE=fixture.gguf
PARAKEET_GGUF_SHA256=$model_sha
PARAKEET_GGUF_SIZE=$model_size
PARAKEET_GGUF_DTYPE=f16
EOF
mkdir -p "$parakeet_home/bin" "$parakeet_home/models/kokoro" "$parakeet_home/models/openwakeword"
make_python "$parakeet_home"
make_wrapper "$parakeet_home/bin/kokoro-cli"
make_wrapper "$parakeet_home/bin/openwakeword-cli"
cat >"$parakeet_home/bin/parakeet-stream" <<'SH'
#!/bin/sh
cat >/dev/null
exit 0
SH
chmod +x "$parakeet_home/bin/parakeet-stream"
printf 'onnx model\n' >"$parakeet_home/models/kokoro/kokoro-v1.0.onnx"
printf 'voices\n' >"$parakeet_home/models/kokoro/voices-v1.0.bin"
printf 'wake model\n' >"$parakeet_home/models/openwakeword/hey_jarvis_v0.1.onnx"
cat >"$parakeet_home/speech.ctl" <<EOF
# Written by tools/install-speech-helpers.sh — applied by boot.sh.
engine kokoro
kokorobin $parakeet_home/bin/kokoro-cli
wakebin $parakeet_home/bin/openwakeword-cli
voice af_bella
wakeword hey jarvis
wakethreshold 0.5
duplex half
whisperstreambin $parakeet_home/bin/parakeet-stream
whispermodel $model
micmode device
capturerate 16000
EOF
PARAKEET_MANIFEST="$manifest" PATH="$FAKEBIN:$PATH" INFERNODE_SPEECH_HOME="$parakeet_home" \
  "$INSTALLER" --check >"$TMP/parakeet-check"
grep -q 'stack: parakeet' "$TMP/parakeet-check"
grep -q 'status: installed' "$TMP/parakeet-check"

# The setup wrapper runs the installer only for an incomplete installation,
# validates before activation, and exposes no secret-looking installer output.
FAKE_INSTALLER="$TMP/fake-installer"
FAKE_COUNT="$TMP/install-count"
FAKE_FAIL="$TMP/fail-install"
FAKE_FINAL_CHECK="$TMP/final-check"
cat >"$FAKE_INSTALLER" <<'SH'
#!/bin/sh
set -eu
if [ "${1:-install}" = --check ]; then
  if [ -n "${FAKE_FINAL_CHECK:-}" ]; then
    checks=0
    [ -f "$FAKE_FINAL_CHECK" ] && checks=$(cat "$FAKE_FINAL_CHECK")
    checks=$((checks + 1))
    printf '%s\n' "$checks" >"$FAKE_FINAL_CHECK"
    if [ "${FAKE_FINAL_FAIL:-0}" = 1 ] && [ "$checks" -ge 3 ]; then
      exit 1
    fi
  fi
  [ -f "$INFERNODE_SPEECH_HOME/valid" ] && exit 0
  exit 1
fi
count=0
[ -f "$FAKE_COUNT" ] && count=$(cat "$FAKE_COUNT")
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_COUNT"
mkdir -p "$INFERNODE_SPEECH_HOME"
if [ "${FAKE_MODE:-success}" = cancel ]; then
  printf partial >"$INFERNODE_SPEECH_HOME/partial"
  while :; do sleep 1; done
fi
if [ -f "$FAKE_FAIL" ]; then
  printf partial >"$INFERNODE_SPEECH_HOME/partial"
  printf 'password=must-not-reach-the-status-file\n'
  exit 9
fi
printf ready >"$INFERNODE_SPEECH_HOME/valid"
printf 'setup helper completed\n'
SH
chmod +x "$FAKE_INSTALLER"
FAKE_TOOLS="$TMP/fake-tools"
mkdir -p "$FAKE_TOOLS"
cp "$SETUP" "$FAKE_TOOLS/speech-setup.sh"
cp "$FAKE_INSTALLER" "$FAKE_TOOLS/install-speech-helpers.sh"
chmod +x "$FAKE_TOOLS/speech-setup.sh" "$FAKE_TOOLS/install-speech-helpers.sh"
FAKE_SETUP="$FAKE_TOOLS/speech-setup.sh"

run_setup() {
  local home=$1
  local status=$2
  local cancel=$3
  env FAKE_COUNT="$FAKE_COUNT" FAKE_FAIL="$FAKE_FAIL" \
    FAKE_FINAL_CHECK="${FAKE_FINAL_CHECK:-}" FAKE_FINAL_FAIL="${FAKE_FINAL_FAIL:-0}" \
    INFERNODE_SPEECH_HOME="$home" FAKE_MODE="${FAKE_MODE:-success}" TMPDIR="$TMP" \
    "$FAKE_SETUP" --status-file "$status" --cancel-file "$cancel"
}

setup_home="$TMP/setup-home"
setup_status="$TMP/setup.status"
setup_cancel="$TMP/setup.cancel"
run_setup "$setup_home" "$setup_status" "$setup_cancel" >"$TMP/setup-first"
[ -f "$setup_home/valid" ]
[ "$(cat "$FAKE_COUNT")" = 1 ]
run_setup "$setup_home" "$setup_status" "$setup_cancel" >"$TMP/setup-second"
[ "$(cat "$FAKE_COUNT")" = 1 ]
grep -q 'nothing was changed' "$TMP/setup-second"

# A failed installer writes only to the staging directory; the old partial
# installation remains byte-for-byte available for a later retry.
partial_home="$TMP/partial-home"
mkdir -p "$partial_home"
printf old >"$partial_home/old"
touch "$FAKE_FAIL"
run_setup "$partial_home" "$TMP/partial.status" "$TMP/partial.cancel" >"$TMP/partial.out" || partial_rc=$?
partial_rc=${partial_rc:-0}
[ "$partial_rc" -ne 0 ]
[ "$(cat "$partial_home/old")" = old ]
[ ! -e "$partial_home/partial" ]
! grep -q 'must-not-reach-the-status-file' "$TMP/partial.status"
! grep -q 'must-not-reach-the-status-file' "$TMP/partial.out"
grep -q 'installer output redacted' "$TMP/partial.status"
rm "$FAKE_FAIL"
FAKE_MODE=success run_setup "$partial_home" "$TMP/retry.status" "$TMP/retry.cancel" >"$TMP/retry.out"
[ -f "$partial_home/valid" ]

# A failure after the directory swap rolls the new tree back before exposing
# it, so a working prior tree is still available for another retry.
final_home="$TMP/final-home"
mkdir -p "$final_home"
printf old >"$final_home/old"
: >"$FAKE_FINAL_CHECK"
FAKE_FINAL_FAIL=1 run_setup "$final_home" "$TMP/final.status" "$TMP/final.cancel" >"$TMP/final.out" || final_rc=$?
final_rc=${final_rc:-0}
[ "$final_rc" -ne 0 ]
[ "$(cat "$final_home/old")" = old ]
[ ! -e "$final_home/valid" ]

# Cancellation is observable and also leaves the prior state intact.
cancel_home="$TMP/cancel-home"
mkdir -p "$cancel_home"
printf old >"$cancel_home/old"
FAKE_MODE=cancel run_setup "$cancel_home" "$TMP/cancel.status" "$TMP/cancel.file" >"$TMP/cancel.out" 2>&1 &
cancel_pid=$!
deadline=$((SECONDS + 10))
while [ "$SECONDS" -lt "$deadline" ]; do
  if grep -q 'phase=installing' "$TMP/cancel.status" 2>/dev/null; then
    : >"$TMP/cancel.file"
    break
  fi
  sleep 0.1
done
wait "$cancel_pid" || cancel_rc=$?
cancel_rc=${cancel_rc:-0}
[ "$cancel_rc" -eq 130 ]
grep -q '^state=cancelled$' "$TMP/cancel.status"
[ "$(cat "$cancel_home/old")" = old ]
[ ! -e "$cancel_home/partial" ]

printf 'PASS: speech detection, staged setup, retry, cancellation, and idempotence\n'
