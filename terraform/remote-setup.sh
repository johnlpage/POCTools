#!/bin/bash
# This script runs on the EC2 host itself (not during cloud-init), uploaded
# and executed by Terraform's terraform_data.provision_app resource - which
# only starts once BOTH terraform_data.bootstrap_app (installs, repo clone,
# DataGen data generation, memex build - see bootstrap.sh) AND the Atlas
# cluster are ready. Only steps that actually need a live Mongo connection
# belong here. Edit this file and re-run `terraform apply` to re-upload and
# re-run it against the already-running instance.
set -euxo pipefail

APP_DIR="$HOME/app"

MEMEX_JAR=$(ls "$APP_DIR"/memex/target/memex-*.jar | grep -v original | head -1)

source "$HOME/.env"

# --- Shard the listing collection before memex starts ---
#mongosh "$MONGO_URI" "$HOME/shard-listing.js"

# Stop any leftover instance from a previous run (idempotent re-runs)
pkill -f "$MEMEX_JAR" 2>/dev/null || true
sleep 1

# Start memex in the background, pointed at the Atlas cluster.
# It is left running after this script exits so you can keep hitting it
# manually via curl over SSH.
# A packaged jar's application.properties may hardcode a database name for
# local dev, which takes precedence over the database name embedded in the
# Mongo URI's path - export both explicitly so the intended Atlas database
# is actually used.
export SPRING_DATA_MONGODB_URI="$MONGO_URI"
export SPRING_DATA_MONGODB_DATABASE="$MONGO_DB_NAME"
nohup java -jar "$MEMEX_JAR" > "$HOME/memex.log" 2>&1 &
MEMEX_PID=$!
echo "memex started with PID $MEMEX_PID, logging to ~/memex.log (left running after this script exits)"

# Wait for it to become healthy (index/search preflight can take a while)
for i in $(seq 1 60); do
  if curl -sf http://localhost:8080/actuator/health | grep -q '"status":"UP"'; then
    echo "memex is healthy"
    break
  fi
  if ! kill -0 "$MEMEX_PID" 2>/dev/null; then
    echo "memex died - see ~/memex.log" >&2
    cat "$HOME/memex.log"
    exit 1
  fi
  sleep 2
done

# --- Run foreground tests against it ---
curl -sf http://localhost:8080/actuator/health
# add further curl invocations / your real test commands here

#for i in $(seq 0 7); do
#  time curl -X POST "http://localhost:8080/api/listings" -H "Content-Type: application/json" -T "/home/ec2-user/listings_${i}.json" > "/home/ec2-user/tests_${i}.log" &
#done
#wait
