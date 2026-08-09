# Host-side deployment bits

These files live on the VPS, not in a container. They are kept in the repo so
the versions in `/usr/local/bin` and `/etc/systemd/system` are tracked.

| Repo file | Installed at |
|---|---|
| `vpn-ts-update.sh` | `/usr/local/bin/vpn-ts-update.sh` |
| `vpn-ts-update.service` | `/etc/systemd/system/vpn-ts-update.service` |
| `vpn-ts-update.timer` | `/etc/systemd/system/vpn-ts-update.timer` |

## Install

```bash
cd /home/batu/services/vpn-ts
sudo install -m 755 deploy/vpn-ts-update.sh /usr/local/bin/vpn-ts-update.sh
sudo install -m 644 deploy/vpn-ts-update.service /etc/systemd/system/
sudo install -m 644 deploy/vpn-ts-update.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vpn-ts-update.timer
```

The script assumes the stack lives at `/home/batu/services/vpn-ts`; override with
`STACK_DIR` (e.g. `Environment=STACK_DIR=/opt/vpn-ts` in the service unit).

## Check / run by hand

```bash
systemctl list-timers vpn-ts-update.timer     # next scheduled run
sudo systemctl start vpn-ts-update.service    # run now
journalctl -u vpn-ts-update.service -n 50     # what it did
```

## Pause it

```bash
sudo systemctl disable --now vpn-ts-update.timer
```
