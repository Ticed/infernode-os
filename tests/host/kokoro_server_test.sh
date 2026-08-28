#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d "$ROOT/tmp/kokoro-server-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home" "$WORK/fake"

cat >"$WORK/fake/kokoro_onnx.py" <<'PY'
import os
import time
import numpy as np


class Kokoro:
    def __init__(self, model, voices):
        with open(os.environ["KOKORO_MARKER"], "a", encoding="ascii") as marker:
            marker.write("loaded\n")

    def create(self, text, voice, speed, lang):
        time.sleep(0.5)
        return np.asarray([0.1, -0.1, 0.1, -0.1], dtype=np.float32), 22050
PY

INFERNODE_SPEECH_HOME="$WORK/home" bash -c \
  "source '$ROOT/tools/install-speech-helpers.sh'; write_wrappers"

KOKORO_MARKER="$WORK/marker" PYTHONPATH="$WORK/fake" \
INFERNODE_SPEECH_HOME="$WORK/home" python3 - "$WORK/home/libexec/kokoro_cli.py" <<'PY'
import os
import struct
import subprocess
import sys

script = sys.argv[1]
env = dict(__import__("os").environ)
p = subprocess.Popen([sys.executable, script, "--server", "--warm"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, env=env)
assert p.stdout.read(6) == b"READY\n"


def send(text):
    payload = text.encode()
    p.stdin.write(("synth 22050 af_bella %d\n" % len(payload)).encode() + payload)
    p.stdin.flush()


def frame():
    header = p.stdout.read(4)
    assert len(header) == 4, header
    length = struct.unpack("<I", header)[0]
    body = p.stdout.read(length)
    assert len(body) == length, (len(body), length)
    return body

send("cancelled")
p.stdin.write(b"cancel\n")
p.stdin.flush()
assert frame() == b""
send("reused")
assert frame()
p.stdin.close()
p.wait(timeout=5)
assert p.returncode == 0, p.stderr.read().decode(errors="replace")
with open(os.environ["KOKORO_MARKER"], encoding="ascii") as marker:
    assert marker.read() == "loaded\n"
print("PASS: resident Kokoro framing, cancellation, and reuse")
PY
