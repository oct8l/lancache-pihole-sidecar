# lancache-pihole-sidecar

A small sidecar container for Pi-hole that keeps LANCache DNS overrides up to date.

It pulls domain lists from [`uklans/cache-domains`](https://github.com/uklans/cache-domains), writes a single managed `dnsmasq` file, and optionally reloads Pi-hole DNS after changes.

This project is env-var driven only (no separate config file).

## How It Works

- Sidecar clones/updates `cache-domains`.
- It generates entries like `address=/domain/LANCACHE_IP` into one managed file.
- Managed file defaults to: `/etc/dnsmasq.d/99-lancache-sidecar.conf`.
- It only rewrites the file when content actually changes.
- If `RELOAD_COMMAND` is set, it runs that command after writes/removals.

Because it uses a dedicated managed file, rollback is straightforward: remove that file and reload Pi-hole.

## Environment Variables

Required when `MODE=run` and `ENABLE=true`:

- `LANCACHE_IP`
  - LANCache server IP(s), comma-separated.
  - Example: `192.168.1.50` or `192.168.1.50,192.168.1.51`

Common:

- `MODE` (default: `run`)
  - `run`: normal reconciliation loop
  - `rollback` or `disable`: remove managed file and exit
- `ENABLE` (default: `true`)
  - `false` keeps sidecar running but removes sidecar records (if `REMOVE_ON_DISABLE=true`)
- `UPDATE_INTERVAL_SECONDS` (default: `21600`)
  - How often to sync and reconcile
- `ONESHOT` (default: `false`)
  - `true` runs once then exits
- `DOMAIN_GROUPS` (default: `all`)
  - Comma-separated group names from `cache_domains.json`
  - `all` uses every group
- `RELOAD_COMMAND` (default: empty)
  - Optional command to reload Pi-hole DNS after change
- `OUTPUT_FILE` (default: `/etc/dnsmasq.d/99-lancache-sidecar.conf`)
- `REMOVE_ON_DISABLE` (default: `true`)
- `STRICT_GROUPS` (default: `true`)
  - If `true`, unknown `DOMAIN_GROUPS` fails the run
- `INCLUDE_LOCAL_DIRECTIVE` (default: `true`)
  - Emits `local=/domain/` alongside `address=/domain/ip`

Advanced:

- `CACHE_DOMAINS_REPO` (default: `https://github.com/uklans/cache-domains.git`)
- `CACHE_DOMAINS_BRANCH` (default: `master`)
- `CACHE_DOMAINS_DIR` (default: `/var/lib/lancache-sidecar/cache-domains`)

## Unraid Sidecar Setup

1. Keep your Pi-hole container as-is.
2. Add this sidecar container and mount Pi-hole's dnsmasq directory into the sidecar at `/etc/dnsmasq.d`.
3. Persist sidecar working data at `/var/lib/lancache-sidecar`.
4. Set env vars (at minimum `LANCACHE_IP`).

Example Docker run-style configuration:

```bash
docker run -d \
  --name lancache-pihole-sidecar \
  --restart unless-stopped \
  -e LANCACHE_IP=192.168.1.50 \
  -e UPDATE_INTERVAL_SECONDS=21600 \
  -e RELOAD_COMMAND='docker exec pihole pihole restartdns reload-lists' \
  -v pihole_dnsmasq:/etc/dnsmasq.d \
  -v lancache_sidecar_data:/var/lib/lancache-sidecar \
  -v /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/oct8l/lancache-pihole-sidecar:latest
```

Notes:

- `RELOAD_COMMAND` is optional, but recommended for immediate effect.
- If you use the docker-exec reload approach, mount `/var/run/docker.sock` and ensure the Pi-hole container name matches.
- If you prefer, omit `RELOAD_COMMAND` and restart Pi-hole DNS manually after changes.
- On Pi-hole v6, ensure `FTLCONF_misc_etc_dnsmasq_d=true` on the Pi-hole container so custom files in `/etc/dnsmasq.d` are loaded.

## Rollback (Return Pi-hole to Normal)

### Option A: One-shot rollback container run

Run the sidecar once with:

- `MODE=rollback`
- same `/etc/dnsmasq.d` mount
- same optional `RELOAD_COMMAND`

This removes only `99-lancache-sidecar.conf`, reloads DNS (if configured), then exits.

### Option B: While sidecar is running

Set:

- `ENABLE=false`

With `REMOVE_ON_DISABLE=true` (default), the sidecar removes its managed file and reloads DNS (if configured).

### Option C: Manual cleanup

- Delete `/etc/dnsmasq.d/99-lancache-sidecar.conf`
- Reload Pi-hole DNS (`pihole restartdns`)

## Build

```bash
docker build -t lancache-pihole-sidecar:local .
```

## Unraid CA Template

Template file:

- `unraid/templates/lancache-pihole-sidecar.xml`

Current template endpoints:

- `ghcr.io/oct8l/lancache-pihole-sidecar:latest`
- `https://github.com/oct8l/lancache-pihole-sidecar`
- `https://raw.githubusercontent.com/oct8l/lancache-pihole-sidecar/main/...`

## Image Publishing (GHCR)

GitHub Actions workflow:

- `.github/workflows/docker-publish.yml`

What it does:

- Triggers on pushes to `main`/`master`, tags like `v1.2.3`, and manual dispatch.
- Builds multi-arch image (`linux/amd64`, `linux/arm64`).
- Pushes tags to `ghcr.io/oct8l/lancache-pihole-sidecar`:
  - branch tags
  - tag refs
  - commit SHA
  - `latest` on default branch

Before first push from Actions:

- In GitHub repo settings, set Actions `Workflow permissions` to `Read and write`.
- After first publish, set package visibility to `Public` in GHCR package settings if you want pulls without auth.

## Quick Test (one-shot)

```bash
docker run --rm \
  -e ONESHOT=true \
  -e LANCACHE_IP=192.168.1.50 \
  -v "$(pwd)/test-dnsmasq:/etc/dnsmasq.d" \
  -v "$(pwd)/test-data:/var/lib/lancache-sidecar" \
  lancache-pihole-sidecar:local
```
