#!/bin/sh
set -e

# --- Static IPs (must match docker-compose.yml) -----------------------------
GLUETUN_IP=172.28.0.2
SWITCHER_IP=172.28.0.4
SWITCHER_PORT=8080
DOCKER_SUBNET=172.28.0.0/24

# Public resolvers used for *exit-node* DNS. These are forced through the VPN
# (see the fwmark rule below) so client DNS lookups don't leak via the VPS IP.
DNS1=1.1.1.1
DNS2=1.0.0.1

# --- Graceful shutdown: forward SIGTERM/SIGINT to tailscaled ----------------
DAEMON_PID=""
term() {
  echo "Received signal, shutting down tailscaled..."
  [ -n "$DAEMON_PID" ] && kill -TERM "$DAEMON_PID" 2>/dev/null
  wait "$DAEMON_PID" 2>/dev/null
  exit 0
}
trap term TERM INT

# --- Wait for Gluetun's VPN to be up ----------------------------------------
# We resolve DNS *through* the VPN now, so Tailscale's own control-plane
# bootstrap needs Gluetun connected first. Gate on the control server.
echo "Waiting for Gluetun VPN to come up (control server ${GLUETUN_IP}:8000)..."
i=0
while [ $i -lt 120 ]; do
  status=$(wget -q -T 2 -O- "http://${GLUETUN_IP}:8000/v1/vpn/status" 2>/dev/null || true)
  case "$status" in
    *running*) echo "Gluetun VPN is running."; break ;;
  esac
  i=$((i + 1))
  sleep 1
done

# --- Force exit-node DNS through the VPN -------------------------------------
# Without this, DNS queries the exit node makes on behalf of clients egress via
# the VPS's real IP (DNS leak). We point the container at public resolvers and
# mark all :53 traffic (except to the local docker subnet) so policy routing
# sends it through Gluetun -> tun0 -> VPN.
echo "nameserver ${DNS1}" > /etc/resolv.conf
echo "nameserver ${DNS2}" >> /etc/resolv.conf

iptables -t mangle -A OUTPUT -p udp --dport 53 ! -d ${DOCKER_SUBNET} -j MARK --set-mark 0x1
iptables -t mangle -A OUTPUT -p tcp --dport 53 ! -d ${DOCKER_SUBNET} -j MARK --set-mark 0x1

# --- Start the daemon -------------------------------------------------------
tailscaled &               # kernel-TUN
DAEMON_PID=$!

# Only consume the (single-use) auth key on first login. Once Tailscale has
# persisted state in the mounted volume, re-running with a spent key would fail,
# so bring it up without one.
if [ -f /var/lib/tailscale/tailscaled.state ]; then
  echo "Existing Tailscale state found; bringing up without auth key."
  tailscale up \
    --hostname="$TS_HOSTNAME" \
    $TS_EXTRA_ARGS \
    --accept-dns=false
else
  echo "No Tailscale state; authenticating with auth key."
  tailscale up \
    --authkey="$TS_AUTHKEY" \
    --hostname="$TS_HOSTNAME" \
    $TS_EXTRA_ARGS \
    --accept-dns=false
fi

while ! ip link show tailscale0 >/dev/null 2>&1; do sleep 1; done

# --- Policy routing: exit-node traffic (and marked DNS) -> Gluetun ----------
ip route add default via ${GLUETUN_IP} dev eth0 table 100
ip rule add from all iif tailscale0 lookup 100 pref 50
ip rule add fwmark 0x1 lookup 100 pref 40   # exit-node DNS -> VPN

# Reverse path filtering is disabled via sysctls in docker-compose.yml
echo "Verifying reverse path filtering settings..."
echo "  all/rp_filter: $(cat /proc/sys/net/ipv4/conf/all/rp_filter)"
echo "  eth0/rp_filter: $(cat /proc/sys/net/ipv4/conf/eth0/rp_filter)"

# --- Forwarding + NAT for exit-node traffic ---------------------------------
iptables -I FORWARD 1 -i tailscale0 -o eth0 -j ACCEPT
iptables -I FORWARD 2 -i eth0 -o tailscale0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -I POSTROUTING 1 -o eth0 -s 100.64.0.0/10 -j MASQUERADE

# --- Kill switch (fail-closed) ----------------------------------------------
# Client exit traffic may ONLY leave via eth0 toward Gluetun. If the route to
# Gluetun is gone, these packets are dropped instead of falling back anywhere.
iptables -A FORWARD -i tailscale0 ! -o eth0 -j DROP

# --- Expose the country switcher over the tailnet (HTTPS, tailnet-only) ------
# Requires HTTPS certificates enabled for the tailnet (admin console).
# Reachable at https://${TS_HOSTNAME}.<tailnet>.ts.net
echo "Configuring tailscale serve -> http://${SWITCHER_IP}:${SWITCHER_PORT}"
tailscale serve --bg --https=443 "http://${SWITCHER_IP}:${SWITCHER_PORT}" || \
  echo "WARN: 'tailscale serve' failed (is HTTPS enabled for the tailnet?)"

wait $DAEMON_PID
