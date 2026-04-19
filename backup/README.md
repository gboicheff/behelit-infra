# Behelit VPS — App Backups

Off-VPS backups for every app deployed via Coolify on the `behelit.xyz`
host. One nightly job, one bucket, one place to look when things break.

## What gets backed up

- **Every running Postgres container** on the host. Auto-discovered —
  add a new app, get backups for free the next night. No per-app
  scripts.
- **`/data/coolify`** (config only). The Coolify control plane:
  Traefik dynamic config, your `.env` files, the GitHub App private
  key, the SSH key Coolify uses to clone, etc. Excludes embedded
  Postgres data dirs (already covered by `pg_dump`) and ACME state
  (re-issued on demand from Let's Encrypt).
- **A manifest** describing what the dump contains.

## What does NOT get backed up

- App-side file uploads (object storage) — none of our apps have any
  yet. Add them here when they appear.
- The OS itself. If the VPS dies, you reinstall from the Coolify quick
  install + restore from B2. ~30 minutes of disaster recovery.
- Container images. They're built from source; the source is in
  GitHub. If a registry vanishes, Coolify rebuilds.

## Storage layout (in B2)

```
behelit-backups/
  <hostname>/
    YYYY-MM-DD/
      achievement-tracker.sql.gz
      bsky.sql.gz
      coolify.sql.gz
      coolify-data.tar.gz
      manifest.txt
```

Retention: **30 days** (configurable via `RETENTION_DAYS` in `.env`).
Backblaze B2 free tier is 10 GB — should be ample for compressed text
dumps for years.

## How container → app-key works

When `run.sh` finds a running `postgres:*` container, it derives a
short, friendly app-key for the output filename. Priority:

1. Container label `backup.name=<key>` (most explicit, recommended for
   non-Coolify containers)
2. Manual override in `/etc/backups/aliases.conf`
3. Coolify resource name (label `coolify.resourceName`) with the
   trailing 22-char UUID stripped — gives clean names like
   `achievement-tracker` for Coolify-managed DBs
4. Docker Compose project name (label `com.docker.compose.project`)
5. Container name as-is (worst case)

You normally don't need to do anything. If you want a specific name,
set the `backup.name` label or use `aliases.conf`.

## VPS setup (one-time)

```bash
# 1. Install rclone
curl https://rclone.org/install.sh | sudo bash

# 2. Configure the B2 remote (interactive, do this once)
rclone config
# - n) New remote
# - name: b2-backups
# - storage: 6 (Backblaze B2)
# - account: <your B2 keyID>
# - key:     <your B2 applicationKey>
# - hard_delete: true
# - leave the rest default

# 3. Drop credentials into /etc/backups/.env (chmod 600)
sudo install -d -m 755 /etc/backups
sudo cp .env.example /etc/backups/.env
sudo chmod 600 /etc/backups/.env
sudo $EDITOR /etc/backups/.env   # set B2_BUCKET + RCLONE_REMOTE

# 4. Drop scripts into /opt/backups
sudo install -d -m 755 /opt/backups
sudo install -m 755 run.sh restore.sh verify-restore.sh /opt/backups/

# 5. Install systemd units
sudo install -m 644 backup-apps.service backup-apps.timer \
                    verify-backup.service verify-backup.timer \
                    /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now backup-apps.timer verify-backup.timer

# 6. Smoke-test now (don't wait until tomorrow to find out it's broken)
sudo /opt/backups/run.sh
```

Verify the timers are scheduled:

```bash
systemctl list-timers backup-apps.timer verify-backup.timer
```

Tail the logs after a run:

```bash
journalctl -u backup-apps.service -n 100 --no-pager
journalctl -u verify-backup.service -n 100 --no-pager
```

## Manual operations

**Trigger a backup right now:**

```bash
sudo systemctl start backup-apps.service
# or, equivalently:
sudo /opt/backups/run.sh
```

**Verify the latest backup is restorable (the weekly job runs this for
you, but it's also fine to invoke ad hoc):**

```bash
sudo /opt/backups/verify-restore.sh
```

**List what's in B2:**

```bash
rclone ls b2-backups:behelit-backups/$(hostname)/
```

**Restore a single app database:**

```bash
sudo /opt/backups/restore.sh
# interactive — pick a date, pick a target

# or non-interactive:
sudo /opt/backups/restore.sh --date 2026-04-19 --target achievement-tracker
```

**Restore Coolify config:**

```bash
sudo /opt/backups/restore.sh --target coolify-data --date 2026-04-19
# stop coolify first if you care about avoiding races:
#   docker stop coolify
# then re-run, then:
#   docker start coolify
```

## Disaster recovery (from-scratch VPS)

1. Provision a new Hetzner VPS, point DNS at it.
2. Install Coolify (`curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash`).
3. Install rclone, recreate `/etc/backups/.env` with the same B2 creds.
4. `sudo /opt/backups/restore.sh --target coolify-data --date <latest>` →
   restart Coolify. Your apps come back from config alone (Coolify
   re-pulls source, rebuilds images).
5. After each app DB container is up, run
   `sudo /opt/backups/restore.sh --target <app> --date <latest>` to
   load its data.
6. Verify, point DNS over, done.

## Why these defaults

- **B2** because the free tier (10 GB stored, 1 GB/day download) covers
  this workload basically forever. Off-VPS so a Hetzner outage doesn't
  take backups with it.
- **Auto-discovery** because hand-maintaining a list of containers is
  exactly the kind of work that goes stale and silently breaks
  backups.
- **Weekly verify** because untested backups are wishful thinking.
  Restoring into a real Postgres + asserting on `information_schema`
  catches dump corruption that file-level checks miss.
