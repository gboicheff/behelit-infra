#!/usr/bin/env bash
#
# Nightly backup of every running Postgres container on this VPS, plus
# the Coolify config directory. Pushes everything to a single Backblaze
# B2 bucket as date-stamped objects, then prunes anything older than
# RETENTION_DAYS.
#
# Containers are AUTO-DISCOVERED — every running `postgres:*` container
# is dumped using the POSTGRES_USER / POSTGRES_DB it was started with.
# Add a new app to the VPS, get backups for free the next night.
#
# Layout in the bucket:
#   <BUCKET>/<HOSTNAME>/YYYY-MM-DD/<app-key>.sql.gz   (one per DB)
#   <BUCKET>/<HOSTNAME>/YYYY-MM-DD/coolify-data.tar.gz
#   <BUCKET>/<HOSTNAME>/YYYY-MM-DD/manifest.txt      (what was backed up)
#
# Designed for systemd timer (see backup-apps.timer) but safe to run
# manually:  sudo /opt/backups/run.sh
#
# Reads B2 creds from /etc/backups/.env (chmod 600). See README.md.

set -euo pipefail

# --------------------------------------------------------------------
# Config
# --------------------------------------------------------------------

ENV_FILE="${ENV_FILE:-/etc/backups/.env}"
ALIAS_FILE="${ALIAS_FILE:-/etc/backups/aliases.conf}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
LOG_TAG="backup-apps"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. See backup/README.md for setup." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${B2_BUCKET:?B2_BUCKET must be set in $ENV_FILE}"
: "${RCLONE_REMOTE:?RCLONE_REMOTE must be set in $ENV_FILE (e.g. b2-backups)}"

HOSTNAME_TAG="$(hostname)"
DATE="$(date -u +%Y-%m-%d)"
WORK_DIR="$(mktemp -d -t backup-apps.XXXXXX)"
MANIFEST="$WORK_DIR/manifest.txt"
trap 'rm -rf "$WORK_DIR"' EXIT

log() {
  logger -t "$LOG_TAG" -- "$*"
  echo "[$LOG_TAG] $*"
}

# --------------------------------------------------------------------
# App-key derivation: turn a Postgres container into a stable, friendly
# filename. Priority:
#   1. Container label `backup.name=<key>`
#   2. Alias defined in /etc/backups/aliases.conf  (one per line:
#      <container-or-project-name>=<key>)
#   3. Coolify resource name (label `coolify.resourceName`) with the
#      trailing -<22-char-uuid> stripped
#   4. Docker Compose project name (label `com.docker.compose.project`)
#   5. Container name as-is
# --------------------------------------------------------------------

declare -A ALIASES
if [[ -f "$ALIAS_FILE" ]]; then
  while IFS='=' read -r raw key; do
    [[ -z "$raw" || "$raw" =~ ^# ]] && continue
    ALIASES["$raw"]="$key"
  done < "$ALIAS_FILE"
fi

container_label() {
  docker inspect "$1" --format "{{ index .Config.Labels \"$2\" }}" 2>/dev/null
}

container_env() {
  docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'
}

derive_key() {
  local container="$1"
  local explicit project resource

  explicit="$(container_label "$container" 'backup.name')"
  if [[ -n "$explicit" ]]; then echo "$explicit"; return; fi

  project="$(container_label "$container" 'com.docker.compose.project')"
  resource="$(container_label "$container" 'coolify.resourceName')"

  # Alias lookups by container, project, or resource name (any match wins)
  for candidate in "$container" "$project" "$resource"; do
    if [[ -n "$candidate" && -n "${ALIASES[$candidate]+x}" ]]; then
      echo "${ALIASES[$candidate]}"
      return
    fi
  done

  if [[ -n "$resource" ]]; then
    # Coolify decorates resourceName with -<20-30 char lowercase uuid>.
    # (Empirically: 24 chars on v4.0.0-beta.473.) Strip if present.
    # NOTE: Coolify also concatenates the env name onto the resource
    # name (e.g. "myapp" + "main" -> "myappmain-<uuid>"). The regex
    # cannot un-glue that; use aliases.conf for friendly final names.
    echo "${resource}" | sed -E 's/-[a-z0-9]{20,30}$//'
    return
  fi

  if [[ -n "$project" ]]; then
    echo "$project"
    return
  fi

  echo "$container"
}

# --------------------------------------------------------------------
# Discovery + dumps
# --------------------------------------------------------------------

discover_postgres_containers() {
  # All running containers whose image starts with "postgres:".
  docker ps --format '{{.Names}} {{.Image}}' \
    | awk '$2 ~ /^postgres:/ { print $1 }'
}

dump_container() {
  local container="$1"
  local user db key out
  user="$(container_env "$container" POSTGRES_USER)"
  db="$(container_env "$container" POSTGRES_DB)"
  if [[ -z "$user" || -z "$db" ]]; then
    log "  - $container: missing POSTGRES_USER/DB env, skipping"
    return 0
  fi
  key="$(derive_key "$container")"
  out="${key}.sql.gz"

  # Avoid two containers ever colliding on the same output filename.
  if [[ -f "$WORK_DIR/$out" ]]; then
    log "  - $container: app-key '$key' collides with another container, suffixing"
    out="${key}-${container}.sql.gz"
  fi

  log "  - $container -> $out (db=$db, user=$user)"
  docker exec "$container" pg_dump \
      --no-owner --no-privileges --clean --if-exists \
      -U "$user" "$db" \
    | gzip --best > "$WORK_DIR/$out"
  local size
  size="$(du -h "$WORK_DIR/$out" | awk '{print $1}')"
  log "    -> $size"
  echo "$key  $container  $db  $user  $out" >> "$MANIFEST"
}

# --------------------------------------------------------------------
# Run
# --------------------------------------------------------------------

log "Starting backup for ${HOSTNAME_TAG} at ${DATE}"
{
  echo "# Backup manifest for ${HOSTNAME_TAG} ${DATE}"
  echo "# Format: <app-key>  <container>  <db>  <user>  <object>"
} > "$MANIFEST"

count=0
for c in $(discover_postgres_containers); do
  dump_container "$c"
  count=$((count + 1))
done

if [[ "$count" -eq 0 ]]; then
  log "WARN: no running postgres containers discovered"
fi

# Coolify config dir: dynamic Traefik configs, .env files, GitHub App
# private key, etc. Excludes embedded Postgres data dirs (we already
# dumped via pg_dump) and the proxy ACME state (re-issued on demand).
if [[ -d /data/coolify ]]; then
  log "  - tarring /data/coolify (config only)"
  tar czf "$WORK_DIR/coolify-data.tar.gz" \
    --exclude='/data/coolify/databases' \
    --exclude='/data/coolify/proxy/acme.json' \
    --exclude='/data/coolify/applications/*/sources' \
    -C / data/coolify
  size="$(du -h "$WORK_DIR/coolify-data.tar.gz" | awk '{print $1}')"
  log "    -> $size"
  echo "_coolify-config  -  -  -  coolify-data.tar.gz" >> "$MANIFEST"
fi

# --------------------------------------------------------------------
# Upload
# --------------------------------------------------------------------

REMOTE_PATH="${RCLONE_REMOTE}:${B2_BUCKET}/${HOSTNAME_TAG}/${DATE}"
log "Uploading to ${REMOTE_PATH}"
rclone copy "$WORK_DIR" "$REMOTE_PATH" \
  --transfers 4 \
  --checkers 4 \
  --b2-hard-delete

# --------------------------------------------------------------------
# Prune old backups
# --------------------------------------------------------------------

PRUNE_BEFORE="$(date -u -d "${RETENTION_DAYS} days ago" +%Y-%m-%d)"
log "Pruning backups older than ${PRUNE_BEFORE} (retention ${RETENTION_DAYS}d)"
rclone lsf "${RCLONE_REMOTE}:${B2_BUCKET}/${HOSTNAME_TAG}/" --dirs-only \
  | sed 's:/$::' \
  | while read -r dir; do
      if [[ "$dir" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ "$dir" < "$PRUNE_BEFORE" ]]; then
        log "  - purging ${dir}"
        rclone purge "${RCLONE_REMOTE}:${B2_BUCKET}/${HOSTNAME_TAG}/${dir}"
      fi
    done

log "Backup completed: ${count} database(s) dumped"
