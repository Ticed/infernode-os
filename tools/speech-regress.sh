#!/usr/bin/env bash
#
# speech-regress.sh — one-command regression suite for the voice/speech stack.
#
# Builds and runs the targeted Limbo suites for the Lucia voice bridge/UI,
# voicemode, speech9p, speechshim9p, and the speech tooling inside the
# emulator, then the host-side installer/helper/audio smoke tests. This is
# deliberately NOT
# ./run-tests.sh:
# it touches only the speech/voice suites, so it is cheap enough to run
# after every change to appl/cmd/voicemode.b, appl/veltro/speech*.b,
# module/speech.m, tools/install-speech-helpers.sh, or the boot wiring.
#
# Pass criteria come from the testing framework's output (a final PASS
# summary and no "--- FAIL:" lines), not only the exit status.
#
# usage: tools/speech-regress.sh [-v]
#   -v   stream each suite's output as it runs (failures always print)

set -u

verbose=0
[ "${1:-}" = "-v" ] && verbose=1

cd "$(dirname "$0")/.." || exit 1
export ROOT=$PWD

case "$(uname -s)" in
Darwin) SYSHOST=MacOSX ;;
Linux)  SYSHOST=Linux ;;
*) echo "speech-regress: unsupported host: $(uname -s)" >&2; exit 1 ;;
esac
objtype=$(uname -m)
case "$objtype" in
arm64|aarch64) objtype=arm64 ;;
x86_64|amd64)  objtype=amd64 ;;
esac
export PATH=$ROOT/$SYSHOST/$objtype/bin:$PATH

EMU=${EMU:-$ROOT/emu/$SYSHOST/o.emu}
if [ ! -x "$EMU" ]; then
  echo "speech-regress: emulator not built: $EMU" >&2
  exit 1
fi

# Emu suites, cheapest protocol tests first. The Lucia bridge/UI suites are
# included because voice controls, approval, live drafts, and TTS lifecycle
# now cross those boundaries.
SUITES="
speechshim_test
remote_speech_topology_test
speech9p_voice_test
speech_wake_test
speech_listen_test
voicemode_test
lucibridge_test
lucibridge_approval_test
luciuisrv_test
speechtest_test
voice_scripts_test
speech_kokoro_test
"

# Built here but run through its host wrapper below because it needs a
# loopback OpenAI-compatible server and deterministic host speech helpers.
BUILD_ONLY_SUITES="speech_e2e_test"

# Rebuild only the suites we run. Without the native mk (fresh clone,
# tools not bootstrapped) fall back to whatever bytecode is already there.
if command -v mk >/dev/null 2>&1; then
  echo "== building test bytecode"
  buildlog=$(mktemp "${TMPDIR:-/tmp}/speech-regress-build.XXXXXX") || {
    echo "speech-regress: could not create build log" >&2
    exit 1
  }
  for t in $SUITES $BUILD_ONLY_SUITES; do
    if ! (cd tests && mk "$t.dis") >>"$buildlog" 2>&1; then
      echo "speech-regress: build failed for $t:" >&2
      cat "$buildlog" >&2
      rm -f "$buildlog"
      exit 1
    fi
  done
  rm -f "$buildlog"
else
  echo "speech-regress: native mk not on PATH; running existing bytecode" >&2
fi

logdir=$(mktemp -d "${TMPDIR:-/tmp}/speech-regress.XXXXXX") || {
  echo "speech-regress: could not create log directory" >&2
  exit 1
}
trap 'rm -rf "$logdir"' EXIT

failed=""
npass=0
nskip=0

run_suite() {
  local name=$1 limit=$2 args=${3:-}
  local log=$logdir/$name.log status ok=0

  printf '== %s ' "$name"
  if [ "$verbose" = 1 ]; then
    echo
    timeout "$limit" "$EMU" -r. "/tests/$name.dis" $args 2>&1 | tee "$log"
    status=${PIPESTATUS[0]}
  else
    timeout "$limit" "$EMU" -r. "/tests/$name.dis" $args >"$log" 2>&1
    status=$?
  fi

  # Inferno's emulator does not have one portable success exit status after
  # the test program finishes: it may exit normally, be reaped by timeout(1),
  # or terminate itself with SIGKILL (137 on Linux). The testing framework's
  # final PASS marker, with no failure marker, is the authoritative verdict.
  if grep -q '^PASS$' "$log" && ! grep -q -- '--- FAIL:' "$log"; then
    ok=1
  fi

  if [ "$ok" = 1 ]; then
    echo "PASS"
    npass=$((npass + 1))
  else
    echo "FAIL (exit $status)"
    failed="$failed $name"
    if [ "$verbose" != 1 ]; then
      echo "---- tail of $name output ----"
      tail -30 "$log"
      echo "------------------------------"
    fi
  fi
}

for t in $SUITES; do
  limit=240
  args=""
  [ "$t" = remote_speech_topology_test ] && limit=15
  [ "$t" = remote_speech_topology_test ] && args="-p $((20000 + $$ % 10000))"
  [ "$t" = speech_kokoro_test ] && limit=120
  run_suite "$t" "$limit" "$args"
done

run_host_test() {
  local name=$1 log status=0 skips
  log=$logdir/$name.log

  printf '== %s ' "$name"
  bash "tests/host/$name" >"$log" 2>&1 || status=$?
  case "$status" in
  0)
    skips=$(grep '^SKIP:' "$log" 2>/dev/null | tr '\n' ';' || true)
    if [ -n "$skips" ]; then
      echo "PASS (partial: ${skips%;})"
    else
      echo "PASS"
    fi
    npass=$((npass + 1))
    ;;
  77)
    echo "SKIP ($(grep '^SKIP:' "$log" | head -1))"
    nskip=$((nskip + 1))
    ;;
  *)
    echo "FAIL (exit $status)"
    failed="$failed $name"
    echo "---- tail of $name output ----"
    tail -30 "$log"
    echo "----------------------------------"
    ;;
  esac
}

# This is the blocking composed path: real Lucia/LLM/speech services with
# deterministic loopback fixtures replacing only microphones and models.
run_host_test speech_e2e_test.sh
run_host_test voice_ui_contract_test.sh
run_host_test parakeet_turn_gate_test.sh
run_host_test elevenlabs_speech_e2e_test.sh
run_host_test remote_speech_scripts_test.sh
run_host_test parakeet_distribution_test.sh

# Topology 3's Android frontend. Hermetic: a fake adb and nc stand in for the
# phone. It guards the silent-zero capture failure — Android silences the
# microphone without erroring, so the export stays reachable while every PCM
# sample is zero and the Mac-side STT just times out. The launcher must refuse
# to call that "ready".
run_host_test android_speech_frontend_test.sh

# The download test is hermetic: it sources the installer with a fake curl.
run_host_test speech_installer_download_test.sh

# The helper test returns 77 when no helper install exists. Its deterministic
# stdin-PCM coverage still runs without microphone permission when installed.
run_host_test speech_helpers_test.sh
run_host_test kokoro_server_test.sh

# CoreAudio coverage is meaningful only on macOS. It reports partial skips
# when the current session lacks an audio device or TCC microphone permission.
if [ "$(uname -s)" = Darwin ]; then
  run_host_test audio_macos_test.sh
  run_host_test audio_device_select_test.sh
  # The microphone-free rig: a loopback audio device stands in for both
  # the microphone and the speaker, so these assert the live device path
  # without depending on the room, the capture gain, or anyone speaking.
  # Both skip when no loopback driver is installed — see
  # docs/SPEECH-VIRTUAL-AUDIO.md.
  run_host_test virtual_audio_loopback_test.sh
  run_host_test virtual_mic_speech_test.sh
  # The whole turn over one device: wake word, utterance, spoken reply,
  # and the half-duplex suppression that keeps the stack from answering
  # its own voice — which only means anything when playback and capture
  # share a device, as they do on a laptop.
  run_host_test virtual_voice_turn_test.sh
  # The same turn through the desktop, asserted on the pixels: the wake
  # word lighting the Voice tile, partials in the unsent turn, the send
  # countdown counting, the answer drawn and spoken. Needs a logged-in
  # session with Screen Recording and Accessibility permission, so it
  # skips on a build machine.
  run_host_test gui_voice_turn_test.sh
fi

echo
if [ -n "$failed" ]; then
  echo "speech-regress: FAIL:$failed"
  exit 1
fi
if [ "$nskip" -gt 0 ]; then
  echo "speech-regress: $npass passed, $nskip skipped"
else
  echo "speech-regress: all $npass suites passed"
fi
