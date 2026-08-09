#!/bin/sh
# Weekly unattended update of the tailscale container.
#
# Installed on the VPS as /usr/local/bin/vpn-ts-update.sh and fired by
# vpn-ts-update.timer. Only the tailscale image is touched -- gluetun is pinned
# to a digest in docker-compose.yml on purpose and is bumped by hand.
#
# Note: `tailscale set --auto-update` is not usable here. Inside a container the
# updated binary is written to the writable layer, which is discarded whenever
# the container is recreated (and this stack recreates containers often).
set -eu

STACK_DIR=${STACK_DIR:-/home/batu/services/vpn-ts}
IMAGE=tailscale/tailscale:stable

cd "$STACK_DIR"

# docker compose v2, falling back to the v1 binary.
if docker compose version >/dev/null 2>&1; then
  compose() { docker compose "$@"; }
else
  compose() { docker-compose "$@"; }
fi

before=$(docker inspect --format '{{.Image}}' tailscale 2>/dev/null || echo none)

compose pull tailscale
after=$(docker image inspect --format '{{.Id}}' "$IMAGE")

if [ "$before" = "$after" ]; then
  echo "tailscale already up to date ($after)"
  exit 0
fi

echo "new image: $before -> $after; recreating container"
compose up -d tailscale

# Wait for tailscaled to come back before declaring success. start-tailscale.sh
# first blocks on gluetun's control server, so give it room.
i=0
while [ $i -lt 60 ]; do
  if docker exec tailscale tailscale status >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 2
done

if ! docker exec tailscale tailscale status >/dev/null 2>&1; then
  echo "ERROR: tailscale did not come back up after the update" >&2
  docker logs --tail 50 tailscale >&2 || true
  exit 1
fi

docker exec tailscale tailscale version
docker exec tailscale tailscale status | head -5
docker image prune -f
