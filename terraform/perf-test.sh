#!/bin/bash
# Runs on the EC2 host itself, uploaded and executed by Terraform's
# terraform_data.perf_test resource - which only starts once
# terraform_data.provision_app has fully finished (memex started, healthy,
# and any initial data/setup done). This is a full perf-test pass:
#
#   Phase 1: sequential (not parallel) bulk load of every listings_*.json
#            file via POST /api/listings, timing the whole pass.
#   Phase 2: sequential reload of listings_0/1/2.json via
#            POST /api/listings?futz=true (exercises the update/"modify on
#            load" write path against already-loaded documents, since the
#            default REPLACE update strategy upserts by _id), done twice,
#            each pass timed SEPARATELY. Pass 1 inserts fresh futz-modified
#            documents on top of Phase 1's plain load (an insert/replace
#            mix); pass 2 is the one that actually measures pure update
#            performance, since every document already exists at that
#            point - this is the number that matters most.
#   Phase 3: generate a fresh 10,000-query Atlas Search pool and replay it
#            with 32 concurrent threads via SearchPerfTest/run_queries.sh.
#
# Edit this file and re-run `terraform apply` to re-upload and re-run it
# against the already-running instance (same pattern as remote-setup.sh).
set -euxo pipefail

APP_DIR="$HOME/ListTest"
LISTINGS_DIR="$HOME"
RESULTS_DIR="$HOME/perftest-results"
mkdir -p "$RESULTS_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SUMMARY="$RESULTS_DIR/summary_${TIMESTAMP}.txt"

log() {
  echo "$@" | tee -a "$SUMMARY"
}

elapsed_since() {
  # $1 = start time (from `date +%s.%N`)
  awk -v s="$1" -v e="$(date +%s.%N)" 'BEGIN{printf "%.3f", e-s}'
}

log "=== Perf test run started at $(date -u +%FT%TZ) ==="

# ---------------------------------------------------------------------------
# Phase 1: sequential bulk load of all listings_*.json files, one at a time,
# recording the overall wall-clock time for the whole pass.
# ---------------------------------------------------------------------------
log "--- Phase 1: sequential bulk load of all listings_*.json files ---"
PHASE1_START=$(date +%s.%N)
for f in "$LISTINGS_DIR"/listings_*.json; do
  log "Loading $f"
  curl -sf -X POST "http://localhost:8080/api/listings" \
    -H "Content-Type: application/json" \
    -T "$f" -o /dev/null
done
PHASE1_ELAPSED=$(elapsed_since "$PHASE1_START")
log "Phase 1 total time: ${PHASE1_ELAPSED}s"

# ---------------------------------------------------------------------------
# Phase 2: reload listings_0/1/2.json with futz=true, sequentially, two full
# passes, each pass timed and recorded SEPARATELY (not combined) - pass 2 is
# the meaningful "pure update" measurement, since pass 1's documents already
# exist going into pass 2 (from Phase 1's load), so pass 2 exercises the
# update path exclusively rather than a mix of inserts/updates.
# ---------------------------------------------------------------------------
log "--- Phase 2: futz=true reload of listings_0/1/2.json, 2 passes (timed separately) ---"

log "--- Phase 2, pass 1 ---"
PHASE2_PASS1_START=$(date +%s.%N)
for i in 0 1 2; do
  f="$LISTINGS_DIR/listings_${i}.json"
  log "Pass 1: futz-loading $f"
  curl -sf -X POST "http://localhost:8080/api/listings?futz=true" \
    -H "Content-Type: application/json" \
    -T "$f" -o /dev/null
done
PHASE2_PASS1_ELAPSED=$(elapsed_since "$PHASE2_PASS1_START")
log "Phase 2 pass 1 time: ${PHASE2_PASS1_ELAPSED}s"

log "--- Phase 2, pass 2 (pure update - documents already exist from pass 1) ---"
PHASE2_PASS2_START=$(date +%s.%N)
for i in 0 1 2; do
  f="$LISTINGS_DIR/listings_${i}.json"
  log "Pass 2: futz-loading $f"
  curl -sf -X POST "http://localhost:8080/api/listings?futz=true" \
    -H "Content-Type: application/json" \
    -T "$f" -o /dev/null
done
PHASE2_PASS2_ELAPSED=$(elapsed_since "$PHASE2_PASS2_START")
log "Phase 2 pass 2 time: ${PHASE2_PASS2_ELAPSED}s"

# ---------------------------------------------------------------------------
# Phase 3: generate 10,000 Atlas Search queries and replay them with 32
# concurrent threads via SearchPerfTest/run_queries.sh.
# ---------------------------------------------------------------------------
log "--- Phase 3: SearchPerfTest - 10,000 queries, 32 parallel ---"
cd "$APP_DIR/SearchPerfTest"
python3 generate_queries.py --count 10000 2>&1 | tee -a "$SUMMARY"

SEARCH_RESULTS_CSV="$RESULTS_DIR/search_perf_${TIMESTAMP}.csv"
./run_queries.sh \
  http://localhost:8080/api/listings/search \
  queries \
  10000 \
  96 \
  "$SEARCH_RESULTS_CSV" 2>&1 | tee -a "$SUMMARY"

log "=== Perf test run finished at $(date -u +%FT%TZ) ==="
log ""
log "Summary:"
log "  Phase 1 (sequential bulk load, all files):              ${PHASE1_ELAPSED}s"
log "  Phase 2 pass 1 (futz=true, files 0-2, insert/replace mix): ${PHASE2_PASS1_ELAPSED}s"
log "  Phase 2 pass 2 (futz=true, files 0-2, PURE UPDATE):        ${PHASE2_PASS2_ELAPSED}s  <-- the number that matters"
log "  Phase 3 (Atlas Search, 10,000 queries, 32 threads): see $SEARCH_RESULTS_CSV / above"
log ""
log "Full log: $SUMMARY"
