#!/bin/bash
set -euo pipefail

PIPELINE="${1:-$HOME/bin/dictate-pipeline}"
TEST_ROOT=$(mktemp -d /tmp/dictate-pipeline-harness.XXXXXX)
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$TEST_ROOT/home/Library/Logs"
python3 - "$TEST_ROOT/long.wav" <<'PY'
import sys, wave
with wave.open(sys.argv[1], "wb") as wav:
    wav.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
    wav.writeframes(b"\0\0" * 16000 * 100)
PY
python3 - "$TEST_ROOT/short.wav" <<'PY'
import sys, wave
with wave.open(sys.argv[1], "wb") as wav:
    wav.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
    wav.writeframes(b"\0\0" * 16000 * 10)
PY

PORT=18127
python3 - "$PORT" "$TEST_ROOT/requests" <<'PY' &
import http.server, pathlib, sys
port, counter_path = int(sys.argv[1]), pathlib.Path(sys.argv[2])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        count = int(counter_path.read_text()) + 1 if counter_path.exists() else 1
        counter_path.write_text(str(count))
        body = f"фрагмент {count}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
SERVER_PID=$!

for _ in $(seq 1 50); do
  if curl -sS --max-time 1 "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done

OUTPUT=$(HOME="$TEST_ROOT/home" WHISPER_SERVER_URL="http://127.0.0.1:$PORT/inference" "$PIPELINE" "$TEST_ROOT/long.wav")
EXPECTED=$'фрагмент 1\nфрагмент 2\nфрагмент 3'
[ "$OUTPUT" = "$EXPECTED" ] || { printf 'unexpected transcript:\n%s\n' "$OUTPUT"; exit 1; }
[ "$(cat "$TEST_ROOT/requests")" = "3" ]
[ ! -e "$TEST_ROOT/long.wav" ]
[ -s "$TEST_ROOT/home/Library/Application Support/SolarCopilot/last-dictation.wav" ]

python3 - "$TEST_ROOT/home/Library/Application Support/SolarCopilot/last-dictation.wav" <<'PY'
import sys, wave
with wave.open(sys.argv[1], "rb") as wav:
    duration = wav.getnframes() / wav.getframerate()
assert duration == 100.0, duration
PY

SHORT_OUTPUT=$(HOME="$TEST_ROOT/home" WHISPER_SERVER_URL="http://127.0.0.1:$PORT/inference" "$PIPELINE" "$TEST_ROOT/short.wav")
[ "$SHORT_OUTPUT" = "фрагмент 4" ]
[ "$(cat "$TEST_ROOT/requests")" = "4" ]
python3 - "$TEST_ROOT/home/Library/Application Support/SolarCopilot/last-dictation.wav" <<'PY'
import sys, wave
with wave.open(sys.argv[1], "rb") as wav:
    duration = wav.getnframes() / wav.getframerate()
assert duration == 10.0, duration
PY

echo "PASS: 100s -> 3 ordered chunks; 10s -> 1 request; latest recovery WAV retained"
