#!/usr/bin/env bash
#
# Weekly self-test. Pulls the most recent backup and verifies EVERY
# .sql.gz it finds: restores into a throwaway Postgres container and
# runs a sanity query. Exits non-zero (alerting via systemd) on any
# failure.
#
# This is the difference between "we have backups" and "we have
# WORKING backups". Untested backups are wishful thinking.

set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/backups/.env}"
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${B2_BUCKET:?}" "${RCLONE_REMOTE:?}"

HOSTNAME_TAG="$(hostname)"
WORK_DIR="$(mktemp -d -t verify-restore.XXXXXX)"
TEST_CONTAINER="restore-verify-$$"
trap 'rm -rf "$WORK_DIR"; docker rm -f "$TEST_CONTAINER" >/dev/null 2>&1 || true' EXIT

LOG_TAG="backup-verify"
log() { logger -t "$LOG_TAG" -- "$*"; echo "[$LOG_TAG] $*"; }

LATEST="$(
  rclone lsf "${RCLONE_REMOTE}:${B2_BUCKET}/${HOSTNAME_TAG}/" --dirs-only \
    | sed 's:/$::' \
    | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
    | sort -r | head -n1
)"

if [[ -z "$LATEST" ]]; then
  log "FAIL: no backups found in B2"
  exit 1
fi
log "Verifying backup ${LATEST}"

# Throwaway Postgres. Use the OLDEST major version among prod
# containers as the lowest common denominator. (Newer versions can
# always restore older dumps; the reverse isn't guaranteed.)
log "Starting throwaway postgres (postgres:15-alpine)..."
docker run -d --rm \
  --name "$TEST_CONTAINER" \
  -e POSTGRES_PASSWORD=verify \
  -e POSTGRES_USER=verify \
  -e POSTGRES_DB=verify \
  postgres:15-alpine >/dev/null

for _ in {1..30}; do
  if docker exec "$TEST_CONTAINER" pg_isready -U verify >/dev/null 2>&1; then break; fi
  sleep 1
done

mapfile -t SQL_OBJECTS < <(
  rclone lsf "${RCLONE_REMOTE}:${B2_BUCKET}/${HOSTNAME_TAG}/${LATEST}/" \
    | grep -E '\.sql\.gz$' || true
)

if [[ ${#SQL_OBJECTS[@]} -eq 0 ]]; then
  log "FAIL: no .sql.gz files in latest backup"
  exit 1
fi

failures=0
verified=0

for object in "${SQL_OBJECTS[@]}"; do
  key="${object%.sql.gz}"
  log "  - ${object}"
  if ! rclone copy "${RCLONE_REMOTE}:${B2_BUCKET}/${HOSTNAME_TAG}/${LATEST}/${object}" "$WORK_DIR" --no-traverse 2>/dev/null; then
    log "    FAIL: download failed"
    failures=$((failures + 1)); continue
  fi
  # Each dump goes into its own throwaway DB so they can't collide.
  testdb="vt_$(echo "$key" | tr -c 'a-zA-Z0-9' '_')"
  docker exec "$TEST_CONTAINER" createdb -U verify "$testdb" >/dev/null 2>&1 || true
  if ! gunzip -c "$WORK_DIR/$object" | docker exec -i "$TEST_CONTAINER" \
       psql -U verify -d "$testdb" -v ON_ERROR_STOP=1 >/dev/null 2>&1; then
    log "    FAIL: psql restore returned non-zero"
    failures=$((failures + 1)); continue
  fi
  # Generic sanity check: at least one user table exists.
  count="$(docker exec "$TEST_CONTAINER" psql -U verify -d "$testdb" -tAc \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null || echo ERR)"
  if [[ "$count" == "ERR" || "$count" == "0" ]]; then
    log "    FAIL: sanity query (count=$count)"
    failures=$((failures + 1)); continue
  fi
  log "    OK (${count} public tables)"
  verified=$((verified + 1))
done

if [[ "$failures" -gt 0 ]]; then
  log "FAIL: ${failures} dump(s) failed verification (${verified} OK)"
  exit 1
fi
log "All ${verified} dump(s) verified OK"
