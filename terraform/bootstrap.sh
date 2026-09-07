#!/bin/bash
# Runs on the EC2 host as soon as cloud-init finishes - has NO dependency on
# the Atlas cluster existing, so Terraform runs this concurrently with Atlas
# cluster creation (terraform_data.bootstrap_app only depends on the EC2
# instance/EIP, not on any mongodbatlas_* resource). This is where the slow,
# Mongo-independent steps (package installs, DataGen data generation, memex
# build) live, so they overlap with the ~10-12 minute Atlas cluster
# provisioning time instead of running after it.
#
# APP_DIR's contents are uploaded here by provision.tf's "file" provisioner
# (from local.app_source_dir on the machine running terraform) BEFORE this
# script runs - the app lives in a private repo, not a public one this
# script can git clone, so it arrives pre-staged instead. This script does
# not fetch or update it.
#
# Idempotent by design: every step either checks-before-acting or is safe to
# repeat, so re-running this (e.g. after editing it and re-applying) never
# needs to destroy/recreate the EC2 instance and never redoes already-done
# expensive work (DataGen generation in particular).
set -euxo pipefail

APP_DIR="$HOME/app"
LISTINGS_DIR="$HOME"
LISTINGS_PREFIX="listings"
NUM_FILES=8
DOCS_PER_FILE=1000000

# --- Sanity-check the app source was actually uploaded before we try to use it ---
if [ ! -d "$APP_DIR/DataGen" ] || [ ! -d "$APP_DIR/memex" ]; then
  echo "ERROR: $APP_DIR is missing DataGen/ and/or memex/ - the file provisioner" >&2
  echo "in provision.tf should have uploaded local.app_source_dir here before" >&2
  echo "bootstrap.sh ran. Check that app_source_dir (terraform/app-src by" >&2
  echo "default - see terraform/app-src/README.md) points at a real checkout." >&2
  exit 1
fi

# --- Ensure Java is available (defensive - cloud-init should have installed it already) ---
command -v java >/dev/null 2>&1 || sudo dnf install -y java-21-amazon-corretto-devel
java -version

# --- Ensure Maven is available ---
command -v mvn >/dev/null 2>&1 || sudo dnf install -y maven
mvn -version

# --- Ensure mongosh is available (needed for shard-listing.js if/when run manually) ---
if ! command -v mongosh >/dev/null 2>&1; then
  sudo tee /etc/yum.repos.d/mongodb-org-8.0.repo > /dev/null <<'REPO'
[mongodb-org-8.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/9/mongodb-org/8.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-8.0.asc
REPO
  sudo dnf install -y mongodb-mongosh
fi
mongosh --version

# --- Generate sample data via DataGen (skip if already generated - this is
#     the ~15 minute step this script exists to run in parallel with Atlas).
#     $NUM_FILES instances are run concurrently, each producing its own
#     output file of $DOCS_PER_FILE documents, so they are meant to be
#     loaded in parallel (e.g. one mongoimport per file) rather than
#     concatenated. Each instance is given a non-overlapping oneupStart
#     (see DataGen/README.md) so the @ONEUP-derived listingId/zpid fields
#     do not collide across files, and a distinct randomSeed so the
#     instances don't all draw the same sequence of random field values.
#
#     ONEUP_STRIDE must be DOCS_PER_FILE times the number of @ONEUP fields
#     that share the counter per document - currently 2 (listingId and
#     zpid both use @ONEUP, see DataGen/Zillow/{listingId,zpid}.csv.gz),
#     since generating DOCS_PER_FILE documents consumes 2 * DOCS_PER_FILE
#     counter values, not DOCS_PER_FILE. Using a stride of just
#     DOCS_PER_FILE here previously caused each file's range to overlap
#     the next by 50%, producing duplicate listingId/zpid values (and
#     resulting E11000 duplicate key errors on load) between adjacent
#     files - e.g. file 0 consumed values 1..2000000 while file 1 started
#     at 1000001, re-emitting values 1000001..2000000 that file 0 had
#     already used. If a CSV file is added under Zillow/ that introduces
#     another @ONEUP field, this multiplier must go up accordingly.
ONEUP_FIELDS_PER_DOC=2
ONEUP_STRIDE=$((DOCS_PER_FILE * ONEUP_FIELDS_PER_DOC))
#
#     A file only counts as "done" if it has exactly $DOCS_PER_FILE lines
#     (DataGen writes one JSON document per line) - a file left over from a
#     run that was interrupted partway (e.g. instance stopped, script
#     killed) will have fewer lines and is not valid input to skip on. Any
#     such partial file is deleted so the generation step below regenerates
#     it from scratch rather than silently loading truncated data later. ---
is_file_complete() {
  local file="$1"
  [ -f "$file" ] || return 1
  local lines
  lines=$(wc -l < "$file")
  [ "$lines" -eq "$DOCS_PER_FILE" ]
}

ALL_FILES_PRESENT=true
for i in $(seq 0 $((NUM_FILES - 1))); do
  OUT_FILE="$LISTINGS_DIR/${LISTINGS_PREFIX}_${i}.json"
  if is_file_complete "$OUT_FILE"; then
    continue
  fi
  ALL_FILES_PRESENT=false
  rm -f "$OUT_FILE"
done

if [ "$ALL_FILES_PRESENT" = true ]; then
  echo "${LISTINGS_PREFIX}_0.json .. ${LISTINGS_PREFIX}_$((NUM_FILES - 1)).json already exist with $DOCS_PER_FILE lines each, skipping DataGen"
else
  cd "$APP_DIR/DataGen"
  mvn -Dmaven.test.skip=true clean package
  PIDS=()
  for i in $(seq 0 $((NUM_FILES - 1))); do
    OUT_FILE="$LISTINGS_DIR/${LISTINGS_PREFIX}_${i}.json"
    [ -f "$OUT_FILE" ] && continue
    ONEUP_START=$((i * ONEUP_STRIDE))
    java -jar target/DataGen-1.0.jar Zillow "$DOCS_PER_FILE" "$OUT_FILE" 2000 "$ONEUP_START" "$i" &
    PIDS+=($!)
  done
  for pid in "${PIDS[@]}"; do
    wait "$pid"
  done
fi

# --- Build memex (server) ---
# Note: -DskipTests only skips *running* tests, it still compiles them. The
# upstream repo's test sources don't compile cleanly, so use
# -Dmaven.test.skip=true instead, which skips compiling tests entirely.
# Safe to re-run: Maven produces the same jar given the same source.
mvn -f "$APP_DIR/memex/pom.xml" -q -Dmaven.test.skip=true package

echo "bootstrap.sh complete: app source in place, ${LISTINGS_PREFIX}_0.json .. ${LISTINGS_PREFIX}_$((NUM_FILES - 1)).json ready, memex jar built."
