#!/bin/sh
# speech9p must obtain its API credential from factotum, not argv.
# The API probe uses a dummy key and a loopback-only endpoint.

set -eu
if [ -z "${ROOT:-}" ]; then
	ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fi
export ROOT
. "$(dirname "$0")/common.sh"

SRC="$ROOT/appl/veltro/speech9p.b"

# Source-level regression assertions make the compatibility decision explicit:
# -k and a package-level plaintext apikey assignment must not return.
if grep -Eq "'k'[[:space:]]*=>.*earg|^apikey[[:space:]]*:=" "$SRC"; then
	echo "FAIL: speech9p still accepts or stores an API key from argv" >&2
	exit 1
fi
grep -Eq 'getuserpasswd\("proto=pass service=openai"\)' "$SRC" || {
	echo "FAIL: speech9p does not retrieve the openai key from factotum" >&2
	exit 1
}

echo "PASS: -k/package-level API key storage is absent"

[ -x "$EMU" ] || { echo "SKIP: emulator not built"; exit 77; }
[ -f "$ROOT/dis/veltro/speech9p.dis" ] || { echo "SKIP: speech9p bytecode not built"; exit 77; }

work=$(mktemp -d "${TMPDIR:-/tmp}/speech9p-factotum.XXXXXX")
cleanup()
{
	[ -n "${emu_pid:-}" ] && kill -9 "$emu_pid" 2>/dev/null || true
	[ -n "${api_pid:-}" ] && kill "$api_pid" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

python3 - "$work" >"$work/api.log" 2>&1 <<'PY' &
import pathlib
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

state = pathlib.Path(sys.argv[1])
expected = "Bearer DUMMY_SPEECH_API_KEY"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def do_POST(self):
        auth = self.headers.get("Authorization", "")
        (state / "authorization").write_text(auth, encoding="ascii")
        if auth != expected:
            self.send_response(401)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = b"\x00\x00"
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(state / "port").write_text(str(server.server_address[1]), encoding="ascii")
server.serve_forever()
PY
api_pid=$!

for _ in $(seq 1 100); do
	[ -s "$work/port" ] && break
	sleep 0.05
done
[ -s "$work/port" ] || { cat "$work/api.log" >&2; echo "FAIL: API stub did not start" >&2; exit 1; }
port=$(cat "$work/port")
url="http://127.0.0.1:$port/v1"
script="$work/probe.sh"
cat > "$script" <<EOF
load std
path=(/dis .)
mount -ac {mntgen} /n >[2] /dev/null
bind -a '#I' /net >[2] /dev/null
ndb/cs
auth/factotum >[2] /dev/null
echo 'key proto=pass service=openai user=apikey !password=DUMMY_SPEECH_API_KEY' > /mnt/factotum/ctl >[2] /dev/null
/dis/veltro/speech9p.dis -m /tmp/speech9p-factotum -e api -u $url >[2] /tmp/speech9p-factotum.log &
sleep 1
echo SPEECH9P_AUTH_PROBE > /tmp/speech9p-factotum/say
sleep 2
kill Speech9p Styx >[2] /dev/null
EOF

"$EMU" -r"$ROOT" /dis/sh.dis "$script" >"$work/emu.log" 2>&1 &
emu_pid=$!
# The request is made asynchronously by speech9p; bound the probe.
for _ in $(seq 1 100); do
	[ -s "$work/authorization" ] && break
	kill -0 "$emu_pid" 2>/dev/null || break
	sleep 0.1
done
wait "$emu_pid" 2>/dev/null || true
emu_pid=

[ -f "$work/authorization" ] || {
	cat "$work/emu.log" >&2
	echo "FAIL: speech9p did not reach the API endpoint" >&2
	exit 1
}
authorization=$(cat "$work/authorization")
[ "$authorization" = "Bearer DUMMY_SPEECH_API_KEY" ] || {
	echo "FAIL: API request did not carry the factotum credential" >&2
	exit 1
}

echo "PASS: speech9p authenticated its API request with service=openai from factotum"
