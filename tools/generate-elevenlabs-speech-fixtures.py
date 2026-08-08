#!/usr/bin/env python3
"""Generate the committed speech E2E corpus with ElevenLabs.

The API key is read only from ELEVENLABS_API_KEY or XI_API_KEY. It is never
written to disk or printed. CI consumes the resulting PCM and metadata offline;
this generator is only for an intentional corpus refresh.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import urllib.error
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DIR = ROOT / "tests/fixtures/speech/elevenlabs"
DEFAULT_VOICE = "21m00Tcm4TlvDq8ikWAM"  # ElevenLabs premade Rachel voice.
DEFAULT_MODEL = "eleven_multilingual_v2"
SAMPLE_RATE = 16000
LEADING_MS = 250
TRAILING_MS = 1200
SEED = 8675309


def parse_manifest(path: Path) -> list[tuple[str, str, str, int]]:
    rows: list[tuple[str, str, str, int]] = []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw or raw.startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) != 4:
            raise ValueError(f"{path}:{number}: expected four tab-separated fields")
        fixture_id, text, keywords, min_partials = parts
        if not fixture_id.replace("_", "").isalnum():
            raise ValueError(f"{path}:{number}: unsafe fixture id {fixture_id!r}")
        rows.append((fixture_id, text, keywords, int(min_partials)))
    if not rows:
        raise ValueError(f"{path}: no fixtures")
    return rows


def request_pcm(key: str, voice: str, model: str, text: str) -> bytes:
    query = urllib.parse.urlencode({"output_format": "pcm_16000"})
    url = f"https://api.elevenlabs.io/v1/text-to-speech/{voice}?{query}"
    body = json.dumps(
        {
            "text": text,
            "model_id": model,
            "seed": SEED,
            "voice_settings": {
                "stability": 0.5,
                "similarity_boost": 0.75,
                "style": 0.0,
                "use_speaker_boost": True,
            },
        },
        separators=(",", ":"),
    ).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "xi-api-key": key,
            "accept": "application/octet-stream",
            "content-type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            pcm = response.read()
    except urllib.error.HTTPError as error:
        detail = error.read(512).decode("utf-8", "replace")
        raise RuntimeError(f"ElevenLabs returned HTTP {error.code}: {detail}") from error
    if not pcm or len(pcm) % 2:
        raise RuntimeError("ElevenLabs did not return non-empty 16-bit PCM")
    return pcm


def silence(milliseconds: int) -> bytes:
    return struct.pack("<h", 0) * (SAMPLE_RATE * milliseconds // 1000)


def last_active_sample(pcm: bytes, threshold: int = 180) -> int:
    samples = memoryview(pcm).cast("h")
    window = SAMPLE_RATE // 50  # 20ms
    for end in range(len(samples), 0, -window):
        start = max(0, end - window)
        if max(abs(int(sample)) for sample in samples[start:end]) >= threshold:
            return end
    return len(samples)


def atomic_write(path: Path, data: bytes) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(data)
    os.replace(temporary, path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_DIR)
    parser.add_argument("--voice-id", default=DEFAULT_VOICE)
    parser.add_argument("--model-id", default=DEFAULT_MODEL)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    key = os.environ.get("ELEVENLABS_API_KEY") or os.environ.get("XI_API_KEY")
    if not key:
        parser.error("export ELEVENLABS_API_KEY (or XI_API_KEY) before generating fixtures")

    output_dir = args.output_dir.resolve()
    manifest = output_dir / "utterances.tsv"
    rows = parse_manifest(manifest)
    output_dir.mkdir(parents=True, exist_ok=True)

    for fixture_id, text, keywords, min_partials in rows:
        pcm_path = output_dir / f"{fixture_id}.pcm"
        text_path = output_dir / f"{fixture_id}.txt"
        meta_path = output_dir / f"{fixture_id}.meta"
        if not args.force and any(path.exists() for path in (pcm_path, text_path, meta_path)):
            raise RuntimeError(f"{fixture_id}: output exists; pass --force for an intentional refresh")

        print(f"Generating {fixture_id} with ElevenLabs...", flush=True)
        speech = request_pcm(key, args.voice_id, args.model_id, text)
        fixture = silence(LEADING_MS) + speech + silence(TRAILING_MS)
        active_samples = last_active_sample(speech)
        speech_end_ms = LEADING_MS + (active_samples * 1000 // SAMPLE_RATE)
        duration_ms = len(fixture) // 2 * 1000 // SAMPLE_RATE
        sha256 = hashlib.sha256(fixture).hexdigest()
        generated = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
        metadata = "\n".join(
            [
                "provider=ElevenLabs",
                f"voice_id={args.voice_id}",
                f"model_id={args.model_id}",
                f"seed={SEED}",
                "sample_rate=16000",
                "channels=1",
                "sample_format=s16le",
                f"leading_silence_ms={LEADING_MS}",
                f"trailing_silence_ms={TRAILING_MS}",
                f"speech_end_ms={speech_end_ms}",
                f"api_pcm_ms={len(speech) // 2 * 1000 // SAMPLE_RATE}",
                f"duration_ms={duration_ms}",
                f"expected_keywords={keywords}",
                f"min_partials={min_partials}",
                f"sha256={sha256}",
                f"generated_utc={generated}",
                "generator=tools/generate-elevenlabs-speech-fixtures.py",
                "",
            ]
        ).encode("utf-8")
        atomic_write(pcm_path, fixture)
        atomic_write(text_path, (text + "\n").encode("utf-8"))
        atomic_write(meta_path, metadata)
        print(f"  {pcm_path.relative_to(ROOT)} sha256={sha256}")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
