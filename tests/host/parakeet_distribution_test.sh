#!/usr/bin/env bash
set -euo pipefail

ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
requirements="$ROOT/tools/parakeet-convert-requirements.txt"
[ -f "$requirements" ] || { echo 'FAIL: conversion requirements are missing' >&2; exit 1; }
grep -q '^nemo_toolkit\[asr\]==2\.7\.3$' "$requirements"
grep -q '^gguf==0\.17\.1$' "$requirements"
grep -q "torch==2\.7\.1" "$ROOT/tools/convert-parakeet-eou.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/parakeet-distribution.XXXXXX")
trap 'find "$tmp" -depth -delete 2>/dev/null || true' EXIT

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

printf 'source checkpoint\n' >"$tmp/source.nemo"
printf 'converted gguf\n' >"$tmp/expected.gguf"
source_sha=$(sha256_file "$tmp/source.nemo")
output_sha=$(sha256_file "$tmp/expected.gguf")
source_size=$(wc -c <"$tmp/source.nemo" | tr -d ' ')
output_size=$(wc -c <"$tmp/expected.gguf" | tr -d ' ')

cat >"$tmp/manifest" <<EOF
PARAKEET_CPP_REPO_URL=https://example.invalid/parakeet.cpp.git
PARAKEET_CPP_COMMIT=1111111111111111111111111111111111111111
PARAKEET_MODEL_REPO=example/parakeet
PARAKEET_MODEL_REVISION=2222222222222222222222222222222222222222
PARAKEET_MODEL_FILE=source.nemo
PARAKEET_MODEL_SHA256=$source_sha
PARAKEET_MODEL_SIZE=$source_size
PARAKEET_GGUF_REPO=example/parakeet-gguf
PARAKEET_GGUF_REVISION=3333333333333333333333333333333333333333
PARAKEET_GGUF_FILE=expected.gguf
PARAKEET_GGUF_SHA256=$output_sha
PARAKEET_GGUF_SIZE=$output_size
PARAKEET_GGUF_DTYPE=f16
EOF

cat >"$tmp/converter" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$FAKE_CONVERTER_LOG"
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
cp "$FAKE_CONVERTER_OUTPUT" "$out"
SH
chmod +x "$tmp/converter"

export FAKE_CONVERTER_LOG="$tmp/converter.log"
export FAKE_CONVERTER_OUTPUT="$tmp/expected.gguf"
PARAKEET_MANIFEST="$tmp/manifest" \
PARAKEET_SOURCE_MODEL="$tmp/source.nemo" \
PARAKEET_CONVERTER="$tmp/converter" \
PARAKEET_CONVERT_PYTHON=bash \
  "$ROOT/tools/convert-parakeet-eou.sh" --work "$tmp/work" --output "$tmp/output.gguf"
cmp "$tmp/expected.gguf" "$tmp/output.gguf"
grep -q -- '--model .*source.nemo --dtype f16 --output .*output.gguf.tmp' "$FAKE_CONVERTER_LOG"

PARAKEET_MANIFEST="$tmp/manifest" \
  "$ROOT/tools/convert-parakeet-eou.sh" --verify "$tmp/output.gguf" >/dev/null
printf 'corrupt\n' >"$tmp/output.gguf"
if PARAKEET_MANIFEST="$tmp/manifest" \
    "$ROOT/tools/convert-parakeet-eou.sh" --verify "$tmp/output.gguf" >/dev/null 2>&1; then
  echo 'FAIL: corrupt converted model passed manifest verification' >&2
  exit 1
fi

mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
cp "$FAKE_DOWNLOAD" "$out"
SH
chmod +x "$tmp/bin/curl"

export PATH="$tmp/bin:$PATH"
export PARAKEET_MANIFEST="$tmp/manifest"
export INFERNODE_SPEECH_HOME="$tmp/install"
export PARAKEET_EOU_URL=https://example.invalid/pinned.gguf
export FAKE_DOWNLOAD="$tmp/expected.gguf"
# Sourcing exposes installer functions without running the full installation.
source "$ROOT/tools/install-speech-helpers.sh"
mkdir -p "$PARAKEET_DIR"
installed=$(find_parakeet_eou_model)
[ "$installed" = "$PARAKEET_DIR/$PARAKEET_GGUF_FILE" ]
cmp "$tmp/expected.gguf" "$installed"

printf 'unverified\n' >"$tmp/unverified.gguf"
PARAKEET_EOU_MODEL="$tmp/unverified.gguf"
[ -z "$(find_parakeet_eou_model)" ]
PARAKEET_ALLOW_UNVERIFIED_MODEL=1
[ "$(find_parakeet_eou_model)" = "$tmp/unverified.gguf" ]

grep -Fq 'git -C "$PARAKEET_SRC" checkout --detach "$PARAKEET_REPO_COMMIT"' \
  "$ROOT/tools/install-speech-helpers.sh"

echo 'PASS: Parakeet conversion and installation use pinned, verified artifacts'
echo 'PASS'
