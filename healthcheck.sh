#!/bin/sh

# Health check script for Gluetun
# Pings a reliable host to check for internet connectivity.
# If connectivity is lost, it kills the container so Docker can restart it.

TARGET_HOST="1.1.1.1"
CHECK_INTERVAL=60
PING_TIMEOUT=5
RETRY_DELAY=3
MAX_RETRIES=2
INITIAL_DELAY=15

echo "Starting connectivity health check..."
echo "Target: $TARGET_HOST"
echo "waiting ${INITIAL_DELAY}s before starting..."
sleep $INITIAL_DELAY
echo "Interval: ${CHECK_INTERVAL}s"

while true; do
  # Try to ping
  if ! ping -c 1 -W $PING_TIMEOUT $TARGET_HOST >/dev/null 2>&1; then
    echo "$(date): Ping failed. Retrying in ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY

    # Retry 1
    if ! ping -c 1 -W $PING_TIMEOUT $TARGET_HOST >/dev/null 2>&1; then
       echo "$(date): Retry 1 failed. Retrying in ${RETRY_DELAY}s..."
       sleep $RETRY_DELAY

       # Retry 2 (Total failure condition reached)
       if ! ping -c 1 -W $PING_TIMEOUT $TARGET_HOST >/dev/null 2>&1; then
         echo "$(date): connectivity lost (failed 3 times). Killing container..."
         # Kill the main process (PID 1) to trigger a container restart
         kill 1
         exit 1
       fi
    fi
    echo "$(date): Connectivity recovered."
  fi

  sleep $CHECK_INTERVAL
done
