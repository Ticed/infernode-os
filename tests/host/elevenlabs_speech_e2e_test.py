#!/usr/bin/env python3
"""Replay committed ElevenLabs PCM through the real Parakeet adapter."""

from __future__ import annotations

import hashlib
import math
import os
from pathlib import Path
import queue
import random
import re
import struct
import subprocess
import sys
import threading
import time


ROOT = Path(os.environ.get("ROOT", Path(__file__).resolve().parents[2])).resolve()
FIXTURES = ROOT / "tests/fixtures/speech/elevenlabs"
MANIFEST = FIXTURES / "utterances.tsv"
PARAKEET_MANIFEST = Path(
    os.environ.get("PARAKEET_MANIFEST", ROOT / "tools/parakeet-eou.manifest")
)
REQUIRED = os.environ.get("INFERNODE_SPEECH_REAL_AUDIO_REQUIRED") == "1"
SAMPLE_RATE = 16000
BYTES_PER_SAMPLE = 2
CHUNK_MS = 100
CHUNK_BYTES = SAMPLE_RATE * BYTES_PER_SAMPLE * CHUNK_MS // 1000


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def skip(message: str) -> None:
    if REQUIRED:
        fail(message)
    print(f"SKIP: {message}")
    raise SystemExit(77)


def read_manifest() -> list[dict[str, object]]:
    fixtures: list[dict[str, object]] = []
    for raw in MANIFEST.read_text(encoding="utf-8").splitlines():
        if not raw or raw.startswith("#"):
            continue
        fixture_id, text, keywords, min_partials = raw.split("\t")
        fixtures.append(
            {
                "id": fixture_id,
                "text": text,
                "keywords": keywords.split(","),
                "min_partials": int(min_partials),
            }
        )
    return fixtures


def read_meta(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw:
            continue
        key, separator, value = raw.partition("=")
        if not separator:
            fail(f"{path}: malformed metadata line {raw!r}")
        values[key] = value
    return values


def manifest_pin(key: str) -> str:
    # The installer sources this manifest to decide what it writes to disk,
    # so reading it here keeps the two from drifting apart.
    for raw in PARAKEET_MANIFEST.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        name, separator, value = line.partition("=")
        if separator and name == key:
            return value
    fail(f"{PARAKEET_MANIFEST}: {key} is not declared")
    raise AssertionError("unreachable")


def find_runtime() -> tuple[Path, Path]:
    home = Path.home() / ".local/share/infernode-speech"
    binary = Path(os.environ.get("PARAKEET_STREAM_BIN", home / "bin/parakeet-stream"))
    model = Path(
        os.environ.get(
            "PARAKEET_MODEL",
            home / "models/parakeet" / manifest_pin("PARAKEET_GGUF_FILE"),
        )
    )
    if not binary.is_file() or not os.access(binary, os.X_OK):
        skip(f"Parakeet adapter is unavailable at {binary}")
    if not model.is_file():
        skip(f"Parakeet model is unavailable at {model}")
    return binary, model


def normalized(text: str) -> str:
    return " ".join(re.findall(r"[a-z0-9]+", text.lower()))


def word_error_rate(expected: str, heard: str) -> float:
    reference = normalized(expected).split()
    hypothesis = normalized(heard).split()
    previous = list(range(len(hypothesis) + 1))
    for row, reference_word in enumerate(reference, 1):
        current = [row]
        for column, hypothesis_word in enumerate(hypothesis, 1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[column] + 1,
                    previous[column - 1] + (reference_word != hypothesis_word),
                )
            )
        previous = current
    return previous[-1] / max(1, len(reference))


# The fixtures carry digital silence between utterances, which no microphone
# ever produces. Replaying them a second time over a noise floor above the
# adapter's quiet-room threshold is what proves turns still close when the
# capture gain or the room puts every block above that level.
#
# The noisy pass asserts less than the quiet pass on purpose. Added noise also
# costs the decoder some end-of-utterance events, so the corpus does not
# segment one-for-one; that is a model property, and holding this test to it
# would make it a Parakeet accuracy benchmark rather than a gate regression.
# What must hold is that turns commit on silence while audio is still
# arriving, which is exactly what the fixed threshold made impossible.
NOISY_ROOM_RMS = 0.0115  # measured: built-in MacBook microphone at full gain
MIN_NOISY_COMMITS = 2


def add_noise(pcm: bytes, rms: float, rng: random.Random) -> bytes:
    if rms <= 0.0:
        return pcm
    count = len(pcm) // 2
    samples = struct.unpack(f"<{count}h", pcm)
    # Uniform noise of the requested RMS: uniform(-a, a) has RMS a/sqrt(3).
    amplitude = rms * math.sqrt(3.0) * 32768.0
    noisy = []
    for sample in samples:
        value = int(sample + rng.uniform(-amplitude, amplitude))
        noisy.append(max(-32768, min(32767, value)))
    return struct.pack(f"<{count}h", *noisy)


def run_pass(
    fixtures: list[dict[str, object]],
    binary: Path,
    model: Path,
    noise_rms: float,
    label: str,
) -> tuple[list[tuple[float, str]], list[tuple[float, str]], float]:
    """Stream the corpus once; return (records, finals, stream duration)."""
    rng = random.Random(8675309)
    command = [
        str(binary),
        "--stdin",
        "--model",
        str(model),
        "--rate",
        "16000",
        "--chans",
        "1",
        "--final-silence-ms",
        "800",
        "--ready",
    ]
    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
        text=False,
    )
    assert process.stdin is not None and process.stdout is not None and process.stderr is not None

    ready = threading.Event()
    output: queue.Queue[tuple[float, str]] = queue.Queue()
    stderr_lines: list[str] = []
    origin = [0.0]

    def read_stdout() -> None:
        for raw in iter(process.stdout.readline, b""):
            stamp = time.monotonic() - origin[0] if origin[0] else -1.0
            output.put((stamp, raw.decode("utf-8", "replace").strip()))

    def read_stderr() -> None:
        for raw in iter(process.stderr.readline, b""):
            line = raw.decode("utf-8", "replace").strip()
            stderr_lines.append(line)
            if line == "ready":
                ready.set()

    stdout_thread = threading.Thread(target=read_stdout, daemon=True)
    stderr_thread = threading.Thread(target=read_stderr, daemon=True)
    stdout_thread.start()
    stderr_thread.start()
    if not ready.wait(120):
        process.kill()
        fail("Parakeet adapter did not announce readiness; reinstall speech helpers")

    origin[0] = time.monotonic()
    stream_cursor = 0.0
    for fixture in fixtures:
        meta = fixture["meta"]
        assert isinstance(meta, dict)
        fixture["speech_end_s"] = stream_cursor + int(meta["speech_end_ms"]) / 1000.0
        pcm = fixture["pcm"]
        assert isinstance(pcm, bytes)
        pcm = add_noise(pcm, noise_rms, rng)
        for offset in range(0, len(pcm), CHUNK_BYTES):
            deadline = origin[0] + stream_cursor
            remaining = deadline - time.monotonic()
            if remaining > 0:
                time.sleep(remaining)
            process.stdin.write(pcm[offset : offset + CHUNK_BYTES])
            process.stdin.flush()
            stream_cursor += min(CHUNK_BYTES, len(pcm) - offset) / (SAMPLE_RATE * BYTES_PER_SAMPLE)
    process.stdin.close()

    try:
        status = process.wait(timeout=120)
    except subprocess.TimeoutExpired:
        process.kill()
        fail("Parakeet adapter did not finish after fixture EOF")
    stdout_thread.join(timeout=2)
    stderr_thread.join(timeout=2)
    records: list[tuple[float, str]] = []
    while not output.empty():
        records.append(output.get())
    if status != 0:
        fail(f"{label}: Parakeet adapter exited non-zero: " + " | ".join(stderr_lines[-8:]))

    finals: list[tuple[float, str]] = []
    for stamp, line in records:
        if not line.startswith("final "):
            continue
        final_text = line[6:]
        if final_text.startswith("confidence="):
            _, _, final_text = final_text.partition(" ")
        finals.append((stamp, final_text))
    return records, finals, stream_cursor


def assert_one_final_per_utterance(
    fixtures: list[dict[str, object]],
    records: list[tuple[float, str]],
    finals: list[tuple[float, str]],
    label: str,
) -> None:
    if len(finals) != len(fixtures):
        fail(
            f"{label}: expected {len(fixtures)} final records, received "
            f"{len(finals)} — turns are not closing on acoustic silence"
        )

    previous_final = -1.0
    for fixture, (final_stamp, final_text) in zip(fixtures, finals):
        fixture_id = f"{label}/{fixture['id']}"
        speech_end = float(fixture["speech_end_s"])
        partials = {
            line[8:]
            for stamp, line in records
            if previous_final < stamp <= speech_end - 0.20 and line.startswith("partial ")
        }
        if len(partials) < int(fixture["min_partials"]):
            fail(
                f"{fixture_id}: expected {fixture['min_partials']} progressive partials "
                f"before speech ended, received {len(partials)}"
            )
        if final_stamp < speech_end - 0.20:
            fail(
                f"{fixture_id}: final at {final_stamp:.3f}s preceded speech end "
                f"at {speech_end:.3f}s"
            )
        if final_stamp > speech_end + 3.0:
            fail(f"{fixture_id}: final latency exceeded three seconds")
        heard = normalized(final_text)
        error_rate = word_error_rate(str(fixture["text"]), final_text)
        if error_rate > 0.25:
            fail(
                f"{fixture_id}: word error rate {error_rate:.1%} exceeded 25%: "
                f"{final_text}"
            )
        missing_keywords = [word for word in fixture["keywords"] if word not in heard]
        if missing_keywords:
            fail(f"{fixture_id}: final omitted keywords {','.join(missing_keywords)}: {final_text}")
        duplicated_keywords = [
            word for word in fixture["keywords"] if heard.split().count(str(word)) != 1
        ]
        if duplicated_keywords:
            fail(
                f"{fixture_id}: final duplicated marker words "
                f"{','.join(duplicated_keywords)}: {final_text}"
            )
        print(
            f"TRACE fixture={fixture_id} speech_end_ms={speech_end * 1000:.0f} "
            f"final_ms={final_stamp * 1000:.0f} partials={len(partials)} "
            f"wer={error_rate:.3f} text={final_text}"
        )
        previous_final = final_stamp


def assert_commits_while_streaming(
    fixtures: list[dict[str, object]],
    finals: list[tuple[float, str]],
    stream_seconds: float,
    label: str,
) -> None:
    # A final emitted after the input ends proves nothing: the adapter flushes
    # the decoder at EOF regardless. Only a final that lands while audio is
    # still arriving can have come from the silence gate. With a fixed
    # threshold and a floor above it, every commit collapsed into that one
    # EOF flush.
    committed = [(stamp, text) for stamp, text in finals if stamp < stream_seconds - 1.0]
    for stamp, text in finals:
        print(
            f"TRACE {label} final_ms={stamp * 1000:.0f} "
            f"stream_ms={stream_seconds * 1000:.0f} text={text}"
        )
    if len(committed) < MIN_NOISY_COMMITS:
        fail(
            f"{label}: {len(committed)} of {len(finals)} finals arrived before the "
            f"stream ended; expected at least {MIN_NOISY_COMMITS} — the silence "
            f"gate is not committing turns over this noise floor"
        )
    corpus = " ".join(str(fixture["text"]) for fixture in fixtures)
    heard = " ".join(text for _, text in finals)
    error_rate = word_error_rate(corpus, heard)
    if error_rate > 0.25:
        fail(f"{label}: word error rate {error_rate:.1%} exceeded 25%: {heard}")
    print(f"TRACE {label} commits={len(committed)}/{len(finals)} wer={error_rate:.3f}")


def main() -> int:
    fixtures = read_manifest()
    missing = [
        fixture["id"]
        for fixture in fixtures
        if not all((FIXTURES / f"{fixture['id']}.{suffix}").is_file()
                   for suffix in ("pcm", "txt", "meta"))
    ]
    if missing:
        skip(
            "ElevenLabs PCM corpus has not been generated: "
            + ", ".join(str(item) for item in missing)
        )

    for fixture in fixtures:
        fixture_id = str(fixture["id"])
        pcm_path = FIXTURES / f"{fixture_id}.pcm"
        text_path = FIXTURES / f"{fixture_id}.txt"
        meta = read_meta(FIXTURES / f"{fixture_id}.meta")
        fixture["pcm"] = pcm_path.read_bytes()
        fixture["meta"] = meta
        if meta.get("provider") != "ElevenLabs":
            fail(f"{fixture_id}: fixture provenance is not ElevenLabs")
        if meta.get("sample_rate") != "16000" or meta.get("channels") != "1":
            fail(f"{fixture_id}: fixture is not 16kHz mono PCM")
        if meta.get("sample_format") != "s16le":
            fail(f"{fixture_id}: fixture is not signed 16-bit little-endian PCM")
        if meta.get("expected_keywords") != ",".join(fixture["keywords"]):
            fail(f"{fixture_id}: keyword metadata drifted from utterances.tsv")
        if meta.get("min_partials") != str(fixture["min_partials"]):
            fail(f"{fixture_id}: partial-count metadata drifted from utterances.tsv")
        digest = hashlib.sha256(fixture["pcm"]).hexdigest()
        if digest != meta.get("sha256"):
            fail(f"{fixture_id}: PCM SHA-256 does not match metadata")
        if text_path.read_text(encoding="utf-8").strip() != fixture["text"]:
            fail(f"{fixture_id}: transcript text drifted from utterances.tsv")
        if len(fixture["pcm"]) % 2:
            fail(f"{fixture_id}: PCM byte count is not sample aligned")

    binary, model = find_runtime()
    records, finals, _ = run_pass(fixtures, binary, model, 0.0, "quiet")
    assert_one_final_per_utterance(fixtures, records, finals, "quiet")
    _, finals, stream_seconds = run_pass(fixtures, binary, model, NOISY_ROOM_RMS, "noisy")
    assert_commits_while_streaming(fixtures, finals, stream_seconds, "noisy")

    print("PASS: committed fixtures are authentic ElevenLabs 16kHz mono PCM")
    print("PASS: real-time Parakeet partials progress before one final per utterance")
    print("PASS: no final, and therefore no TTS trigger, occurs before speech ends")
    print("PASS: turns still close over a noise floor above the quiet-room threshold")
    print("PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
