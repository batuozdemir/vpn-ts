#!/bin/sh

# Health check for Gluetun.
# Confirms the tunnel is actually up (control server reports "running") AND that
# traffic reaches the internet. A bare ping can pass even when traffic has
# misrouted off the VPN, so we check the tunnel state too. On sustained failure
# we kill PID 1 to let Docker recreate the container (restart: unless-stopped).

CONTROL="http://127.0.0.1:8000"
TARGET_HOST="1.1.1.1"
CHECK_INTERVAL=30
PING_TIMEOUT=5
RETRY_DELAY=3
INITIAL_DELAY=15

echo "Starting Gluetun health check..."
echo "waiting ${INITIAL_DELAY}s before starting..."
sleep $INITIAL_DELAY
echo "Interval: ${CHECK_INTERVAL}s"

# Healthy = VPN status is "running" AND we can reach the internet.
healthy() {
  status=$(wget -q -T 4 -O- "${CONTROL}/v1/vpn/status" 2>/dev/null || true)
  case "$status" in
    *running*) ;;          # tunnel is up
    *) return 1 ;;         # stopped / crashed / control server unreachable
  esac
  ping -c 1 -W $PING_TIMEOUT "$TARGET_HOST" >/dev/null 2>&1
}

while true; do
  if ! healthy; then
    echo "$(date): health check failed. Retrying in ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY
    if ! healthy; then
      echo "$(date): retry 1 failed. Retrying in ${RETRY_DELAY}s..."
      sleep $RETRY_DELAY
      if ! healthy; then
        echo "$(date): VPN unhealthy (failed 3 times). Killing container..."
        kill 1
        exit 1
      fi
    fi
    echo "$(date): recovered."
  else
    # Log current egress so leaks/wrong-country are visible in logs.
    ipinfo=$(wget -q -T 4 -O- "${CONTROL}/v1/publicip/ip" 2>/dev/null || true)
    [ -n "$ipinfo" ] && echo "$(date): egress $ipinfo"
  fi
  sleep $CHECK_INTERVAL
done
