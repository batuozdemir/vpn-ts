# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Docker Compose stack that turns a host into a **Tailscale exit node whose traffic is routed through a Gluetun VPN** (ProtonVPN via WireGuard). Clients on the tailnet select this exit node and their internet traffic egresses through the VPN. There is no application code, build step, or test suite — it is shell scripts plus container orchestration.

## Commands

```bash
# Start / restart the stack
docker-compose up -d
docker-compose down && docker-compose up -d

# Status checks
docker exec tailscale tailscale status
docker exec gluetun wget -qO- https://ifconfig.co   # should show the VPN's (Ireland) IP

# Logs (most debugging happens here)
docker logs -f gluetun
docker logs -f tailscale

# Inspect live routing/firewall state inside a container
docker exec gluetun iptables -t nat -L POSTROUTING -n -v
docker exec tailscale ip rule
```

Secrets live in `.env` (gitignored). Copy `.env.example` → `.env` and fill in `WIREGUARD_PRIVATE_KEY`, `TS_AUTHKEY`, and optionally `SERVER_COUNTRIES` / `TS_HOSTNAME`.

## Architecture

Three containers on a static bridge network `vpn-net` (172.28.0.0/24):

- **gluetun** (172.28.0.2) — the VPN gateway. Connects to ProtonVPN over WireGuard (`tun0`) and NATs forwarded traffic out through it. Exposes a control server on `:8000`.
- **tailscale** (172.28.0.3) — joins the tailnet, advertises itself as an exit node, policy-routes exit traffic to gluetun, and `tailscale serve`s the switcher UI.
- **switcher** (172.28.0.4) — Go web app (`switcher/`) to change exit country; rewrites `SERVER_COUNTRIES` in `.env` and recreates gluetun via the mounted docker socket.

Traffic path: tailnet client → `tailscale0` in the tailscale container → (policy routing table 100) → gluetun `eth0` → gluetun `tun0` → ProtonVPN → internet.

Exit-node **DNS** is forced through the VPN too: the tailscale container uses public resolvers and fwmarks port-53 traffic (`ip rule fwmark 0x1 lookup 100`) so DNS doesn't leak via the VPS IP. Because of this, `start-tailscale.sh` waits for gluetun's control server to report `running` before `tailscale up` (its control-plane DNS now depends on the VPN).

### The critical, non-obvious pieces

Getting one container to route through another, then through a VPN, depends on several settings that must agree. When debugging connectivity, check these first:

1. **Gluetun's built-in firewall is disabled** (`FIREWALL=off` in `docker-compose.yml`). All firewall/NAT rules are applied manually by the scripts instead. `FIREWALL_OUTBOUND_SUBNETS=172.28.0.0/24,100.64.0.0/10` still allows the docker subnet and the Tailscale CGNAT range to talk to gluetun even while gluetun's own rules are managed manually.

2. **Custom entrypoints wrap the stock images.** Both containers override `entrypoint`:
   - `gluetun-entrypoint.sh` starts gluetun's real entrypoint in the background, waits for `tun0`, then runs `setup-gluetun.sh` (forwarding + MASQUERADE rules) and launches `healthcheck.sh`.
   - `start-tailscale.sh` runs `tailscaled`, brings up tailscale, waits for `tailscale0`, then installs the policy route (table 100 → gluetun) and the FORWARD/MASQUERADE rules.

3. **Rules are re-applied on every start**, so the stack survives `down`/`up`. If you change routing logic, edit the scripts (they are bind-mounted into the containers) and restart — no image rebuild needed.

4. **sysctls matter.** `ip_forward` is enabled in compose (the scripts assume it and only verify). The tailscale container also needs `src_valid_mark=1` and `rp_filter=0` (reverse-path filtering off) or asymmetric VPN routing gets dropped.

5. **Auto-restart on connectivity loss.** `healthcheck.sh` pings `1.1.1.1` every 60s (after a 15s initial delay); after 3 consecutive failures it `kill 1`s gluetun's PID 1 so Docker's `restart: unless-stopped` recreates the container and re-runs the entrypoint.

6. **Peer-to-peer tailnet traffic bypasses the VPN** — only exit-node (general internet) traffic is policy-routed through gluetun; the `100.64.0.0/10` MASQUERADE rules target that egress specifically.

### Where to make changes

- VPN provider / region / WireGuard settings → `docker-compose.yml` env + `.env`.
- Routing / NAT / firewall / DNS behavior → `setup-gluetun.sh` (VPN side) and `start-tailscale.sh` (tailnet side).
- Restart/health behavior → `healthcheck.sh`.
- Country switcher → `switcher/main.go` (allow-list, env rewrite, compose recreate). `COMPOSE_PROJECT_NAME` in the switcher service must match the stack's compose project name or it will create duplicate containers instead of recreating gluetun.

A prior audit of this repo lives in `AUDIT.md` (findings + the feature design that produced the switcher).
