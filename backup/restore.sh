#!/usr/bin/env bash
#
# Interactive restore tool. Reads the date's manifest from B2, lists
# every app available, and lets you pick one to restore.
#
# Usage:
#   sudo /opt/backups/restore.sh
#   sudo /opt/backups/restore.sh --date 2026-04-19 --target achievement-tracker
#   sudo /opt/backups/restore.sh --date 2026-04-19 --target coolify-data
#
# This script will REPLACE the contents of the target database. Take a
# fresh ad-hoc backup first if there's any doubt:
#   sudo /opt/backups/run.sh

set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/backups/.env}"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found." >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${B2_BUCKET:?}" "${RCLONE_REMOTE:?}"

HOSTNAME_TAG="$(hostname)"
WORK_DIR="$(mktemp -d -t restore-apps.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

DATE_ARG=""
TARGET_ARG=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --date) DATE_ARG="$2"; shift 2 ;;
    --target) TARGET_ARG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

# --------------------------------------------------------------------
# Date selection
# --------------------------------------------------------------------

if [[ -z "$DATE_ARG" ]]; then
  echo "Available backup dates in ${RCLONE_REMOTE}:${B2_BUCKET}/${HOSTNAME_TAG}/:"
  mapfile -t DATES < <(
    rclone lsf "${RCLONE_REMOTE}:${B2_BUCKET}/${HOSTNAME_TAG}/" --dirs-only \
      | sed 's:/$::' \
      | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
      | sort -r
  )
  if [[ ${#DATES[@]} -eq 0 ]]; then
    echo "No backups found." >&2
    exit 1
  fi
  for i in "${!DATES[@]}"; do
    printf "  [%d] %s\n" "$((i + 1))" "${DATES[$i]}"
  done
  read -rp "Pick number (default 1, the most recent): " CHOICE
  CHOICE="${CHOICE:-1}"
  DATE_ARG="${DATES[$((CHOICE - 1))]}"
fi
echo "Using backup date: ${DATE_ARG}"

# --------------------------------------------------------------------
# Pull manifest to know what's available + which container/db/user maps
# --------------------------------------------------------------------

rclone copy "${RCLONE_REMOTE}:${B2_BUCKET}/${HOSTNAME_TAG}/${DATE_ARG}/manifest.txt" "$WORK_DIR" --no-traverse 2>/dev/null || true

# Manifest is optional — older backups might not have one. Build a
# fallback list directly from the bucket listing.
declare -A APP_OBJECT
declare -A APP_DB
declare -A APP_USER
declare -A APP_HINT_CONTAINER

if [[ -f "$WORK_DIR/manifest.txt" ]]; then
  while read -r key container db user object; do
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    APP_OBJECT["$key"]="$object"
    APP_DB["$key"]="$db"
    APP_USER["$key"]="$user"
    APP_HINT_CONTAINER["$key"]="$container"
  done < "$WORK_DIR/manifest.txt"
else
  # No manifest — derive keys from .sql.gz filenames in the date folder.
  while read -r object; do
    [[ "$object" == *.sql.gz ]] || continue
    key="${object%.sql.gz}"
    APP_OBJECT["$key"]="$object"
    APP_DB["$key"]=""
    APP_USER["$key"]=""
    APP_HINT_CONTAINER["$key"]=""
  done < <(rclone lsf "${RCLONE_REMOTE}:${B2_BUCKET}/${HOSTNAME_TAG}/${DATE_ARG}/")
fi

# Coolify-data is its own animal.
if rclone lsf "${RCLONE_REMOTE}:${B2_BUCKET}/${HOSTNAME_TAG}/${DATE_ARG}/coolify-data.tar.gz" >/dev/null 2>&1; then
  APP_OBJECT["coolify-data"]="coolify-data.tar.gz"
fi

# --------------------------------------------------------------------
# Target selection
# --------------------------------------------------------------------

if [[ -z "$TARGET_ARG" ]]; then
  echo "Available targets in this backup:"
  mapfile -t KEYS < <(printf '%s\n' "${!APP_OBJECT[@]}" | sort)
  for i in "${!KEYS[@]}"; do
    printf "  [%d] %s\n" "$((i + 1))" "${KEYS[$i]}"
  done
  read -rp "Pick number: " CHOICE
  TARGET_ARG="${KEYS[$((CHOICE - 1))]}"
fi

if [[ -z "${APP_OBJECT[$TARGET_ARG]+x}" ]]; then
  echo "Unknown target: $TARGET_ARG" >&2
  echo "Available: ${!APP_OBJECT[*]}" >&2
  exit 2
fi

OBJECT="${APP_OBJECT[$TARGET_ARG]}"
REMOTE_FILE="${RCLONE_REMOTE}:${B2_BUCKET}/${HOSTNAME_TAG}/${DATE_ARG}/${OBJECT}"
echo "Downloading ${REMOTE_FILE}"
rclone copy "$REMOTE_FILE" "$WORK_DIR" --no-traverse

LOCAL_FILE="$WORK_DIR/$OBJECT"
[[ -f "$LOCAL_FILE" ]] || { echo "ERROR: download failed." >&2; exit 1; }
echo "  -> $(du -h "$LOCAL_FILE" | awk '{print $1}')"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run: stopped before applying. File at $LOCAL_FILE"
  trap - EXIT
  echo "(WORK_DIR preserved at $WORK_DIR)"
  exit 0
fi

# --------------------------------------------------------------------
# Apply
# --------------------------------------------------------------------

if [[ "$TARGET_ARG" == "coolify-data" ]]; then
  echo "About to restore /data/coolify from ${OBJECT}."
  echo "This will overwrite existing config files. Stop Coolify first if you care."
  read -rp "Type 'yes' to continue: " CONFIRM
  [[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 1; }
  tar xzf "$LOCAL_FILE" -C /
  echo "Done. You may need to restart coolify-proxy and the coolify container."
  exit 0
fi

# DB restore: figure out which container is currently running for this
# app. Strategy:
#   1. The hinted container name from the manifest, if it still exists.
#   2. Auto-discover by re-deriving the app key from each running
#      postgres container's labels (mirrors run.sh logic).

CURRENT_CONTAINER=""
HINT="${APP_HINT_CONTAINER[$TARGET_ARG]:-}"
if [[ -n "$HINT" ]] && docker ps --format '{{.Names}}' | grep -qx "$HINT"; then
  CURRENT_CONTAINER="$HINT"
fi

container_label() {
  docker inspect "$1" --format "{{ index .Config.Labels \"$2\" }}" 2>/dev/null
}
container_env() {
  docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'
}

# Lightweight re-derivation: same priority as run.sh but without the
# alias file (good enough for restore).
derive_key() {
  local container="$1" project resource explicit
  explicit="$(container_label "$container" 'backup.name')"
  [[ -n "$explicit" ]] && { echo "$explicit"; return; }
  resource="$(container_label "$container" 'coolify.resourceName')"
  if [[ -n "$resource" ]]; then echo "${resource}" | sed -E 's/-[a-z0-9]{20,30}$//'; return; fi
  project="$(container_label "$container" 'com.docker.compose.project')"
  if [[ -n "$project" ]]; then echo "$project"; return; fi
  echo "$container"
}

if [[ -z "$CURRENT_CONTAINER" ]]; then
  for c in $(docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /^postgres:/ { print $1 }'); do
    if [[ "$(derive_key "$c")" == "$TARGET_ARG" ]]; then
      CURRENT_CONTAINER="$c"
      break
    fi
  done
fi

if [[ -z "$CURRENT_CONTAINER" ]]; then
  echo "ERROR: cannot find a currently-running postgres container for app '$TARGET_ARG'." >&2
  echo "Start the app first (or use --target coolify-data if that's what you meant)." >&2
  exit 1
fi

# Pull live db/user from the running container — more reliable than
# trusting the manifest if you've reconfigured between backup and now.
LIVE_USER="$(container_env "$CURRENT_CONTAINER" POSTGRES_USER)"
LIVE_DB="$(container_env "$CURRENT_CONTAINER" POSTGRES_DB)"

echo "About to restore ${OBJECT} INTO container=${CURRENT_CONTAINER}"
echo "  user=${LIVE_USER}  db=${LIVE_DB}"
echo "ALL CURRENT DATA IN THAT DATABASE WILL BE REPLACED."
read -rp "Type 'yes' to continue: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 1; }

gunzip -c "$LOCAL_FILE" | docker exec -i "$CURRENT_CONTAINER" psql -U "$LIVE_USER" -d "$LIVE_DB" -v ON_ERROR_STOP=1
echo "Done."
