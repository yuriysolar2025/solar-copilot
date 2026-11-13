#!/bin/bash
set -euo pipefail

URL="${1:-http://127.0.0.1:8127/inference}"
WAV="${2:?usage: benchmark-whisper.sh URL sample.wav}"
RUNS="${RUNS:-5}"
OUT="${OUT:-/tmp/solar-copilot-whisper-benchmark.tsv}"

request() {
  local mode="$1" run="$2" slot="$3"
  local result
  result=$(curl -sS --max-time 120 -o /dev/null \
    -w '%{http_code}\t%{time_total}' -X POST "$URL" \
    -F "file=@$WAV" -F temperature=0.0 -F language=ru -F response_format=text) || result="curl_error\t120"
  printf '%s\t%s\t%s\t%b\n' "$mode" "$run" "$slot" "$result" >> "$OUT"
}

: > "$OUT"
printf 'mode\trun\tslot\thttp\tseconds\n' >> "$OUT"

for run in $(seq 1 "$RUNS"); do request sequential "$run" 1; done
for width in 2 3; do
  for run in $(seq 1 "$RUNS"); do
    for slot in $(seq 1 "$width"); do request "concurrent-$width" "$run" "$slot" & done
    wait
  done
done

python3 - "$OUT" <<'PY'
import csv, statistics, sys
rows=list(csv.DictReader(open(sys.argv[1]), delimiter='\t'))
for mode in sorted({r['mode'] for r in rows}):
    vals=[float(r['seconds']) for r in rows if r['mode']==mode]
    vals.sort()
    p95=vals[min(len(vals)-1, int(len(vals)*.95))]
    bad=sum(r['http']!='200' for r in rows if r['mode']==mode)
    print(f"{mode}: n={len(vals)} median={statistics.median(vals):.3f}s p95={p95:.3f}s errors={bad}")
PY
