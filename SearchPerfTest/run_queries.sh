#!/bin/bash
# Replay a pool of pre-generated Atlas Search query JSON files (see
# generate_queries.py) against the /api/listings/search endpoint, at a
# specified total request count and parallelism, measuring per-request
# latency via curl's built-in timing.
#
# Usage:
#   ./run_queries.sh [endpoint] [queries_dir] [total_requests] [parallelism] [results_csv]
#
# All arguments are optional and positional; defaults shown below. Pass "-"
# for an argument to keep its default while overriding a later one.
#
# Examples:
#   ./run_queries.sh                                  # smoke test: 100 requests, 1 at a time
#   ./run_queries.sh - - 1000 5                        # 1000 requests, 5 concurrent
#   ./run_queries.sh http://1.2.3.4:8080/api/listings/search - 100000 10   # load test against EC2
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENDPOINT="${1:-http://localhost:8080/api/listings/search}"
QUERIES_DIR="${2:-$SCRIPT_DIR/queries}"
TOTAL="${3:-100}"
PARALLELISM="${4:-1}"
RESULTS_CSV="${5:-$SCRIPT_DIR/results/run_$(date +%Y%m%d_%H%M%S).csv}"

[ "$ENDPOINT" = "-" ] && ENDPOINT="http://localhost:8080/api/listings/search"
[ "$QUERIES_DIR" = "-" ] && QUERIES_DIR="$SCRIPT_DIR/queries"

mkdir -p "$(dirname "$RESULTS_CSV")"

# Pool of available query files, sorted for reproducible cycling.
# (Deliberately not using `mapfile` - not available in macOS's stock bash 3.2.)
POOL=()
while IFS= read -r line; do
  POOL+=("$line")
done < <(find "$QUERIES_DIR" -maxdepth 1 -name 'query_*.json' | sort)
POOL_SIZE=${#POOL[@]}

if [ "$POOL_SIZE" -eq 0 ]; then
  echo "No query_*.json files found in $QUERIES_DIR - run generate_queries.py first." >&2
  exit 1
fi

echo "Endpoint:        $ENDPOINT"
echo "Query pool:      $QUERIES_DIR ($POOL_SIZE distinct queries)"
echo "Total requests:  $TOTAL"
echo "Parallelism:     $PARALLELISM"
echo "Results CSV:     $RESULTS_CSV"
echo "query_file,time_total_seconds,http_status" > "$RESULTS_CSV"

# Build the (possibly cycling, if TOTAL > POOL_SIZE) list of file paths to
# request, then fan out through xargs -P for parallelism.
# -P 1 = strictly sequential/linear; -P 10 = 10 requests in flight at once.
# Cycling is done entirely in awk (fast even for 100k+ requests) rather than
# a bash while-read loop, which would be the bottleneck at that scale.
POOL_FILE=$(mktemp)
trap 'rm -f "$POOL_FILE"' EXIT
printf '%s\n' "${POOL[@]}" > "$POOL_FILE"

START_TIME=$(date +%s.%N)

awk -v poolfile="$POOL_FILE" -v n="$POOL_SIZE" -v total="$TOTAL" '
  BEGIN {
    i = 0
    while ((getline line < poolfile) > 0) {
      i++
      pool[i] = line
    }
    for (r = 1; r <= total; r++) {
      idx = ((r - 1) % n) + 1
      print pool[idx]
    }
  }
' | xargs -P "$PARALLELISM" -I{} sh -c '
    curl -s -o /dev/null -X POST \
      -H "Content-Type: application/json" \
      --data @"{}" \
      -w "{},%{time_total},%{http_code}\n" \
      "$1"
  ' _ "$ENDPOINT" >> "$RESULTS_CSV"

END_TIME=$(date +%s.%N)
ELAPSED=$(awk -v s="$START_TIME" -v e="$END_TIME" 'BEGIN{printf "%.3f", e-s}')

echo ""
echo "Done. $TOTAL requests in ${ELAPSED}s."
echo ""
python3 "$SCRIPT_DIR/summarize.py" "$RESULTS_CSV" --elapsed "$ELAPSED"
