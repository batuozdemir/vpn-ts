#!/bin/sh
# This script runs INSIDE the Gluetun container to configure it as a gateway
# It sets up iptables rules to forward and NAT traffic from Tailscale through the VPN

set -e

echo "Waiting for tun0 interface..."
while ! ip link show tun0 >/dev/null 2>&1; do
  sleep 1
done
echo "tun0 is up!"

echo "Setting up Gluetun as a router for Tailscale..."

# IP forwarding is already enabled via sysctls in docker-compose.yml
# Verify it's enabled
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
  echo "WARNING: IP forwarding is not enabled!"
  exit 1
fi
echo "IP forwarding: enabled"

# Flush any existing rules to start clean
iptables -F FORWARD 2>/dev/null || true
iptables -t nat -F POSTROUTING 2>/dev/null || true

# Set default FORWARD policy to DROP for security
iptables -P FORWARD DROP

# Allow forwarding between Docker network and VPN
iptables -A FORWARD -i eth0 -o tun0 -j ACCEPT
iptables -A FORWARD -i tun0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Allow forwarding for Tailscale CGNAT range specifically
iptables -A FORWARD -s 100.64.0.0/10 -o tun0 -j ACCEPT
iptables -A FORWARD -d 100.64.0.0/10 -i tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# NAT all traffic going out through tun0 (the VPN interface)
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE

# Kill switch (fail-closed): forwarded client traffic may ONLY exit via tun0.
# The FORWARD policy is already DROP, but this makes the intent explicit and
# guards against any future ACCEPT rule accidentally opening an eth0 egress
# path while the VPN is down/reconnecting.
iptables -A FORWARD -i eth0 ! -o tun0 -j DROP

echo "Gluetun routing setup complete!"
echo ""
echo "Current FORWARD rules:"
iptables -L FORWARD -n -v
echo ""
echo "Current NAT POSTROUTING rules:"
iptables -t nat -L POSTROUTING -n -v
