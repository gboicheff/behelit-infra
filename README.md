# behelit-infra

Cross-cutting infrastructure for the apps hosted on `behelit.xyz`.
This repo holds anything that isn't owned by a single app:

- **`backup/`** — Off-VPS Postgres + Coolify backups to Backblaze B2,
  with weekly self-verifying restores. See [`backup/README.md`](backup/README.md).

## Convention

- App-specific code stays in the app repo (e.g. `achievement-tracker`).
- VPS-wide concerns (backups, monitoring, firewall, OS bootstrap) live here.
- Anything checked in is safe to read; secrets live in `/etc/backups/.env`
  on the VPS (chmod 600) and never enter git.
