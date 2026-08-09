# Tailscale Exit Node with VPN Routing

Routes Tailscale exit node traffic through Gluetun VPN (ProtonVPN Ireland).

## Setup

1. Copy `.env.example` to `.env` and fill in your credentials:
   ```bash
   cp .env.example .env
   # Edit .env with your keys
   ```

2. Start containers:
   ```bash
   docker-compose up -d
   ```

## Quick Start

```bash
# Start
docker-compose up -d

# Restart
docker-compose down && docker-compose up -d

# Check status
docker exec tailscale tailscale status
docker exec gluetun wget -qO- https://ifconfig.co
```

## Files

- `docker-compose.yml` - Container configuration
- `start-tailscale.sh` - Tailscale startup with policy routing
- `setup-gluetun.sh` - Gluetun iptables configuration
- `gluetun-entrypoint.sh` - Auto-applies iptables on startup
- `healthcheck.sh` - Verifies tunnel state + connectivity, restarts on failure
- `switcher/` - Go web app to change exit country from the tailnet
- `deploy/` - Host-side update script + systemd timer (installed on the VPS)

## Country switcher (web UI)

A small web app lets you change the VPN exit country from any device on your
tailnet — no SSH.

- URL: `https://<TS_HOSTNAME>.<your-tailnet>.ts.net` (e.g. set `TS_HOSTNAME=vpn`)
- Exposed only on the tailnet via `tailscale serve` (never Funnel/public).
- Picking a country rewrites `SERVER_COUNTRIES` in `.env` and recreates the
  gluetun container (~15-30s reconnect). Current egress country is shown live.

Requirements:
- **HTTPS must be enabled** for your tailnet (admin console → DNS → HTTPS
  Certificates, MagicDNS on).
- `COMPOSE_PROJECT_NAME` in the `switcher` service must match the stack's
  compose project name (the directory you run `docker-compose` from; defaults
  to `vpn-ts`). Otherwise the switcher would create new containers instead of
  recreating the running gluetun.
- The switcher mounts the docker socket; keep it tailnet-locked.

## Keeping Tailscale up to date

The tailscale container tracks the `stable` tag, and a **weekly systemd timer on
the host** re-pulls it and recreates the container (`deploy/`). Tailscale state
lives in the mounted `./tailscale` volume, so recreating never needs the auth key
again, and `start-tailscale.sh` re-applies routing, NAT and `tailscale serve`.

`tailscale set --auto-update` is **not** usable here: inside a container the
updated binary is written to the writable layer, which is discarded on every
recreate (and this stack recreates containers often).

```bash
# Update now, by hand
docker compose pull tailscale && docker compose up -d tailscale
docker exec tailscale tailscale version

# Install / inspect the weekly timer -- see deploy/README.md
sudo systemctl start vpn-ts-update.service
journalctl -u vpn-ts-update.service -n 50
```

**Gluetun is deliberately pinned to a digest** in `docker-compose.yml` and is
*not* auto-updated: its custom entrypoint depends on upstream behaviour, and the
switcher recreates the container on every country change. Bump it by hand:

```bash
docker pull qmcgaw/gluetun:latest
docker image inspect qmcgaw/gluetun:latest --format '{{index .RepoDigests 0}}'
# put that digest in docker-compose.yml, then:
docker compose up -d gluetun
# and re-verify egress IP + DNS leak (see "Verifying after deploy")
```

## Usage from Client

```bash
# Enable exit node
tailscale set --exit-node=vpn-exit-node

# Verify (should show Ireland VPN IP)
curl https://ifconfig.co

# Disable
tailscale set --exit-node=
```

## How It Works

1. Tailscale container receives exit node traffic
2. Policy routing (table 100) sends it to Gluetun (172.28.0.2)
3. Gluetun forwards and NATs traffic through VPN (tun0)
4. Internet traffic exits via ProtonVPN

Exit-node **DNS** is also forced through the VPN: the Tailscale container uses
public resolvers (1.1.1.1) and marks port-53 traffic so it routes via Gluetun,
preventing DNS leaks via the VPS IP.

## Notes

- ✅ Works after restart (`docker-compose down && up`); iptables auto-applied
- ✅ Peer-to-peer Tailscale traffic bypasses VPN
- ✅ Exit-node DNS routed through the VPN (no DNS leak)
- ✅ Fail-closed kill switch (client traffic only exits via the VPN)
- ✅ Auto-restart on health-check failure (tunnel state + connectivity)
- ✅ Change exit country from the tailnet web UI
- ✅ Tailscale container auto-updated weekly (gluetun pinned on purpose)

## Verifying after deploy

```bash
# Egress IP/country (should be the VPN's, from a client using the exit node):
curl https://ifconfig.co/json

# DNS leak test from a client on the exit node — resolver should be the VPN's:
#   visit https://dnsleaktest.com  (or https://www.dnsleaktest.com)

# Live tunnel state on the server:
docker exec gluetun wget -qO- http://127.0.0.1:8000/v1/vpn/status
docker exec gluetun wget -qO- http://127.0.0.1:8000/v1/publicip/ip
```
