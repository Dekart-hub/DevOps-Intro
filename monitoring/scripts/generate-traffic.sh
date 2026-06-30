#!/usr/bin/env bash
# Generate a burst of mostly-healthy mixed traffic against QuickNotes so the
# golden-signal panels show non-trivial data. A small slice of 404s/400s keeps
# the Errors panel non-zero but well under the 5% alert line.
#
# Portable to the stock macOS bash 3.2 (no associative arrays).
#
# Usage: ./generate-traffic.sh [base_url] [rounds]
#   base_url  default http://localhost:8080
#   rounds    default 50  (~4 requests per round = ~200 requests)
set -euo pipefail

BASE="${1:-http://localhost:8080}"
ROUNDS="${2:-50}"

total=0
errs=0
hit() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' "$@" || echo 000)
  total=$((total + 1))
  if [ "$code" -ge 400 ]; then errs=$((errs + 1)); fi
}

echo "firing traffic at $BASE ($ROUNDS rounds)..."
for i in $(seq 1 "$ROUNDS"); do
  # Healthy path: create a note, list, health check, fetch an existing note.
  hit -X POST "$BASE/notes" -H 'Content-Type: application/json' \
      -d "{\"title\":\"note $i\",\"body\":\"from generate-traffic\"}"
  hit "$BASE/notes"
  hit "$BASE/health"
  hit "$BASE/notes/1"
  # Sprinkle a few client errors, kept rare so the baseline stays healthy.
  if [ $((i % 10)) -eq 0 ]; then hit "$BASE/notes/999999"; fi                       # 404
  if [ $((i % 20)) -eq 0 ]; then
    hit -X POST "$BASE/notes" -H 'Content-Type: application/json' -d 'not json'      # 400
  fi
done

pct=0
if [ "$total" -gt 0 ]; then pct=$((errs * 100 / total)); fi
echo "sent $total requests, $errs were 4xx/5xx (${pct}%)."
