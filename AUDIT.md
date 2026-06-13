# Code Audit & Architecture Report

**Repo:** `vpn-ts` — Tailscale exit node routing exit traffic through a Gluetun (ProtonVPN/WireGuard) container.
**Use case (per your notes):** run on a VPS to bypass *local* VPN restrictions by tunneling your VPN through the VPS, reachable over your tailnet.
**Date:** 2026-06-13

---

## 1. Executive summary

The stack works and the routing design is sound: client → `tailscale0` → policy-route table 100 → gluetun `eth0` → `tun0` (ProtonVPN) → internet. The scripts re-apply all rules on every start, so it survives `docker-compose down && up`.

However, for a setup whose *entire point* is privacy/leak-avoidance, there are a few real leak vectors and robustness gaps. None are catastrophic, but two should be fixed before you rely on this:

- **DNS resolution for client traffic egresses over the VPS's real IP, not the VPN** (likely DNS leak). — *High*
- **No kill switch**: with `FIREWALL=off`, there is no hard guarantee that traffic is dropped while the VPN is down/reconnecting; you rely on the absence of a route. — *Medium/High*

Good news from the git audit: **no secrets leaked into history.** `.env` was never committed, and the tracked `repomix-output.xml` (now deleted) only contained the `.env.example` placeholders. Recommend `git rm`-ing it for good and adding `repomix-output.xml` to `.gitignore`.

---

## 2. Findings

### HIGH — DNS leak for client traffic
When a Tailscale client uses an exit node, DNS queries are forwarded to the exit node and **resolved by `tailscaled` inside the container**. That resolution traffic *originates from the container itself*, not from `iif tailscale0`, so your policy rule (`ip rule add from all iif tailscale0 lookup 100`) does **not** match it. It follows the container's main-table default route → docker bridge → host → the VPS's real internet connection. Result: your browsing IP is the VPN's, but your DNS queries can come from the VPS's real IP.

`--accept-dns=false` further means the container uses whatever default resolver it has, compounding this.

**Fix options:**
- Add a policy rule that also routes the container's own DNS (or all container-originated traffic) through gluetun, *or*
- Configure DNS to go through gluetun's built-in DNS-over-TLS (gluetun runs a DNS server on `127.0.0.1:53` by default) and point tailscaled at it, *or*
- Set MagicDNS / Tailscale DNS so clients resolve via a server reached *through* the tunnel.
- **Verify after fixing:** from a client using the exit node, check `https://dnsleaktest.com` (or `dig` against a known echo) — the resolver should be the VPN's, never the VPS's ISP.

### MEDIUM/HIGH — No kill switch (leak window on VPN drop/reconnect)
`FIREWALL=off` disables gluetun's built-in kill switch. Protection currently relies on the fact that when `tun0` drops there is no default route for forwarded packets, so they're dropped. But:
- During gluetun's reconnect, route/firewall state is in flux; the guarantee is implicit, not enforced.
- The health check (below) only reacts after ~3 minutes.

**Fix:** add an explicit drop rule so forwarded client traffic can *only* leave via `tun0`. E.g. in `setup-gluetun.sh`, since `FORWARD` policy is already `DROP`, also ensure there is **no** `FORWARD`/MASQUERADE path via `eth0` for `100.64.0.0/10` (there currently isn't — good), and add an explicit `iptables -A FORWARD -s 100.64.0.0/10 ! -o tun0 -j DROP` as belt-and-suspenders. This makes the kill switch explicit rather than emergent.

### MEDIUM — Health check is slow and only covers gluetun
`healthcheck.sh`: 15s initial delay + 60s interval + 3 failures × ~3s = up to ~3 minutes of dead connectivity before restart. It pings `1.1.1.1`, which tests *internet*, not specifically *that traffic is on the VPN*. A misroute that still has internet (a leak!) would pass the check.

**Improvements:**
- Check the egress IP/country, not just reachability (e.g. periodically curl `https://ifconfig.co/country` through `tun0` and confirm it equals the configured country).
- Shorten the interval, or use gluetun's own `GET /v1/vpn/status` on its control server instead of `kill 1`.
- The check is backgrounded with no supervisor — if `healthcheck.sh` itself dies, nothing restarts it.

### MEDIUM — Signals not forwarded; ungraceful shutdown
Both custom entrypoints run the real process in the background and `wait`, but install **no `trap`** to forward `SIGTERM`. On `docker-compose down`, Docker sends `SIGTERM` to PID 1 (the wrapper shell), which does not pass it to gluetun/tailscaled. They get `SIGKILL`ed after the 10s timeout. This can leave WireGuard/Tailscale state dirty and slows shutdown.

**Fix:** add `trap 'kill -TERM "$CHILD_PID"; wait "$CHILD_PID"' TERM INT` in each entrypoint.

### LOW — `kill 1` semantics in `gluetun-entrypoint.sh`
The health check does `kill 1` to force a restart. PID 1 is `gluetun-entrypoint.sh` (the wrapper), not gluetun. It works (shell dies → container exits → `restart: unless-stopped` recreates it), but it's indirect and tied to point #5. Combined with the missing signal trap, the actual gluetun process is killed abruptly.

### LOW — `set -e` + auth key expiry can cause a restart loop
`start-tailscale.sh` uses `set -e` and runs `tailscale up --authkey=...` on every start. Tailscale state is persisted in `./tailscale`, so re-auth usually isn't needed — but if you used an **ephemeral or one-time** auth key, a restart after key expiry will fail `tailscale up`, exit the script, and loop forever via `restart: unless-stopped`, with no clear error surfaced. *(See question 3.)*

### LOW — `VPN_PORT_FORWARDING=on` is unnecessary and widens exposure
Port forwarding (and `FIREWALL_INPUT_PORTS=51820`) is enabled but nothing in this stack uses an inbound forwarded port — an exit node only needs outbound. ProtonVPN port forwarding opens a public port on the VPN side. Recommend `VPN_PORT_FORWARDING=off` and dropping the related vars unless you have a reason.

### LOW — Repo hygiene
- `git rm --cached repomix-output.xml` (already deleted in working tree) and add `repomix-output.xml` to `.gitignore`.
- Commit `"deneme"` and the leftover `____deneme___` line in `.gitignore` suggest scratch state; tidy up.
- `.env` perms are `-rw-r--r--` (world-readable). On the VPS, `chmod 600 .env`.

### INFO — Two Tailscale instances (host + container)
Per your notes, the VPS host also runs Tailscale. This is fine and is actually *why the design works*: the container's own control-plane/DERP traffic exits via the host's real IP (it isn't matched by the `iif tailscale0` rule), avoiding a chicken-and-egg bootstrap problem. Just be aware both nodes appear in your tailnet; keep their hostnames distinct (`TS_HOSTNAME=vpn-exit-node` is good) and don't accidentally route the host node through the container exit node.

---

## 3. Feature request: web-based country switcher

**Goal:** a page at e.g. `https://vpn.<tailnet>.ts.net` (tailnet-only) to pick a country, which updates the config and restarts the VPN — no SSH.

### Recommended architecture
A small **sidecar container** with its own Tailscale identity, exposing a tiny web app via **`tailscale serve`** (HTTPS, MagicDNS, tailnet-only by default — *do not* use `funnel`, which makes it public).

Two ways to apply the change, pick based on how much you want to touch the running stack:

1. **Recreate gluetun (simple, robust):** the app rewrites `SERVER_COUNTRIES` in `.env`, then runs `docker compose up -d gluetun` (and the dependent `tailscale` if needed). Requires mounting the **docker socket** into the sidecar — powerful, so the sidecar must be tailnet-locked and ideally not run other code.
2. **Gluetun control server (no recreate):** gluetun exposes a control server (`:8000`); you can stop/restart the VPN loop via `PUT /v1/vpn/status`. Server *selection* by country, however, is normally driven by the `SERVER_COUNTRIES` env, so changing country cleanly still wants an env update + restart. Option 1 is the more reliable path for "switch country."

### Sketch
```
sidecar (tailscale serve https) ──> tiny web app
   - GET  /          -> list of countries (current highlighted)
   - POST /set       -> writes SERVER_COUNTRIES=<country> to .env
                        -> docker compose up -d gluetun
                        -> polls gluetun /v1/vpn/status + ifconfig.co until country matches
```
- Lock it down with Tailscale ACLs so only your own user/devices can reach `vpn:443`.
- Keep an allow-list of valid ProtonVPN country names server-side (don't pass user input straight into env/compose).
- Show the *current* egress country on the page (read via gluetun control server or `ifconfig.co`) so you get confirmation the switch worked.

I can implement this once you answer the questions below.

---

## 4. Questions for you

1. **DNS:** Is leak-proof DNS a hard requirement? (It matters a lot for "bypass restrictions." If yes, I'll route container DNS through gluetun and verify with a leak test.) — relates to the HIGH finding.
do it
2. **Kill switch:** Do you want a hard fail-closed guarantee (no packets ever leave except via the VPN, even mid-reconnect)? You tried `FIREWALL=on` and it didn't work — I believe that was because gluetun's firewall blocked the forwarded/Tailscale subnets; with the right `FIREWALL_OUTBOUND_SUBNETS` it can be made to work. Want me to attempt a working `FIREWALL=on` config, or implement an explicit manual kill-switch rule instead?
use your judgement. let's try it.
3. **Tailscale auth key type:** Is `TS_AUTHKEY` reusable/non-expiring, ephemeral, or one-time? This determines whether restarts can fail (LOW finding) and whether the country-switch restart is safe.
it was single use. tailscale remembers its state so I don't need a new authkey unless i delete the tailscale folder on project dir.
4. **Country switcher scope:** Just country, or also specific city/server and a "reconnect/rotate IP" button?
just country.
5. **Who can use the web UI:** only your personal devices, or anyone on the tailnet? (Drives the ACL.)
Anyone on the tailnet
6. **Restart tolerance:** When switching country, a brief drop while gluetun reconnects is unavoidable. Acceptable, or do you want make-before-break (spin a second gluetun, cut over)? The former is far simpler.
acceptable.
7. **Stack you'd prefer for the web app:** Go (single static binary, tiny image) vs. Python/Flask vs. Node? Default recommendation: Go.
Go

---

## 5. Quick wins (low-risk, do anytime)
- `VPN_PORT_FORWARDING=off` (+ remove `FIREWALL_INPUT_PORTS`, `VPN_PORT_FORWARDING_PROVIDER`) unless needed.
- `git rm --cached repomix-output.xml`; add to `.gitignore`.
- `chmod 600 .env` on the VPS.
- Add signal `trap`s to both entrypoints.
- Add the explicit kill-switch DROP rule in `setup-gluetun.sh`.
- Make the health check verify *country*, not just reachability.
