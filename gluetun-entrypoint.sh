#!/bin/sh
# Custom entrypoint that runs Gluetun's default entrypoint
# and then applies our custom iptables rules

echo "Starting Gluetun with custom routing setup..."

# Start Gluetun in the background
/gluetun-entrypoint &
GLUETUN_PID=$!

# Wait for tun0 to be ready
echo "Waiting for VPN connection (tun0)..."
while ! ip link show tun0 >/dev/null 2>&1; do
  sleep 1
done
echo "VPN connected!"

# Apply our custom iptables rules
/setup-gluetun.sh

# Wait for Gluetun process
wait $GLUETUN_PID
