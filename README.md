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
4. Internet traffic exits via ProtonVPN Ireland

## Notes

- ✅ Works after restart (`docker-compose down && up`)
- ✅ iptables rules applied automatically
- ✅ Works after restart (`docker-compose down && up`)
- ✅ iptables rules applied automatically
- ✅ Peer-to-peer Tailscale traffic bypasses VPN
- ✅ Auto-restart on connectivity loss (Health check)
