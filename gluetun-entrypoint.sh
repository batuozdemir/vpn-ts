#!/bin/sh
# Custom entrypoint that runs Gluetun's default entrypoint
# and then applies our custom iptables rules

echo "Starting Gluetun with custom routing setup..."

GLUETUN_PID=""
term() {
  echo "Received signal, shutting down Gluetun..."
  [ -n "$GLUETUN_PID" ] && kill -TERM "$GLUETUN_PID" 2>/dev/null
  wait "$GLUETUN_PID" 2>/dev/null
  exit 0
}
trap term TERM INT

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

# Start health check
/healthcheck.sh &

# Wait for Gluetun process
wait $GLUETUN_PID
