#!/bin/sh
set -e
GLUETUN_IP=172.28.0.2      # match docker-compose

tailscaled &               # kernel-TUN
DAEMON_PID=$!

tailscale up \
  --authkey="$TS_AUTHKEY" \
  --hostname="$TS_HOSTNAME" \
  $TS_EXTRA_ARGS \
  --accept-dns=false

while ! ip link show tailscale0 >/dev/null 2>&1; do sleep 1; done

# Policy routing: Route traffic from tailscale0 through Gluetun
ip route add default via ${GLUETUN_IP} dev eth0 table 100
ip rule add from all iif tailscale0 lookup 100 pref 50

# Reverse path filtering is already disabled via sysctls in docker-compose.yml
# Verify the settings
echo "Verifying reverse path filtering settings..."
echo "  all/rp_filter: $(cat /proc/sys/net/ipv4/conf/all/rp_filter)"
echo "  eth0/rp_filter: $(cat /proc/sys/net/ipv4/conf/eth0/rp_filter)"
if [ -f /proc/sys/net/ipv4/conf/tailscale0/rp_filter ]; then
  echo "  tailscale0/rp_filter: $(cat /proc/sys/net/ipv4/conf/tailscale0/rp_filter)"
fi

# Allow forwarding between tailscale0 and eth0
iptables -I FORWARD 1 -i tailscale0 -o eth0 -j ACCEPT
iptables -I FORWARD 2 -i eth0 -o tailscale0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Masquerade traffic going out through eth0 (to Gluetun)
# This must happen BEFORE Tailscale's own masquerade rules
iptables -t nat -I POSTROUTING 1 -o eth0 -s 100.64.0.0/10 -j MASQUERADE

wait $DAEMON_PID