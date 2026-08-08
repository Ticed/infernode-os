#!/usr/bin/env python3
"""Replay committed ElevenLabs PCM through the real Parakeet adapter."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import queue
import re
import subprocess
import sys
import threading
import time


ROOT = Path(os.environ.get("ROOT", Path(__file__).resolve().parents[2])).resolve()
FIXTURES = ROOT / "tests/fixtures/speech/elevenlabs"
MANIFEST = FIXTURES / "utterances.tsv"
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


def find_runtime() -> tuple[Path, Path]:
    home = Path.home() / ".local/share/infernode-speech"
    binary = Path(os.environ.get("PARAKEET_STREAM_BIN", home / "bin/parakeet-stream"))
    model = Path(
        os.environ.get(
            "PARAKEET_MODEL",
            home / "models/parakeet/parakeet_realtime_eou_120m-v1-f16.gguf",
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
        fail("Parakeet adapter exited non-zero: " + " | ".join(stderr_lines[-8:]))

    finals: list[tuple[float, str]] = []
    for stamp, line in records:
        if not line.startswith("final "):
            continue
        final_text = line[6:]
        if final_text.startswith("confidence="):
            _, _, final_text = final_text.partition(" ")
        finals.append((stamp, final_text))
    if len(finals) != len(fixtures):
        fail(f"expected {len(fixtures)} final records, received {len(finals)}")

    previous_final = -1.0
    for fixture, (final_stamp, final_text) in zip(fixtures, finals):
        fixture_id = str(fixture["id"])
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

    print("PASS: committed fixtures are authentic ElevenLabs 16kHz mono PCM")
    print("PASS: real-time Parakeet partials progress before one final per utterance")
    print("PASS: no final, and therefore no TTS trigger, occurs before speech ends")
    print("PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
