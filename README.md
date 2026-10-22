# ufw-docker

Make plain `ufw allow` and `ufw deny` actually govern **Docker-published ports**.

```bash
sudo ./ufw-docker.sh install
sudo ufw deny 8089/tcp      # ...and this now genuinely closes it
```

> **Not the same project as [`chaifeng/ufw-docker`](https://github.com/chaifeng/ufw-docker).**
> That one solves the same plumbing but adds its own CLI (`ufw-docker allow httpd 80/tcp`).
> This one wires ufw's *existing* rules through instead, so there is no new command to learn.
> If your team is happy to learn one verb, chaifeng's is older and more widely deployed — use it.

## The problem

Docker publishes a port by DNAT in `PREROUTING`, then the packet is **forwarded** to the
container. ufw filters `INPUT`. Forwarded traffic never traverses `INPUT`, so:

```
$ sudo ufw deny 8089/tcp
Rule added

$ sudo ufw status
8089/tcp    DENY    Anywhere

$ curl http://your-host:8089/      # from outside
HTTP 400                            ← still wide open
```

The firewall reports a rule that does nothing. That is the whole problem.

## What this does

Adds a stanza to `/etc/ufw/after.rules` that routes forwarded, container-bound traffic
through ufw's own `ufw-user-input` chain — the same chain `ufw allow` writes to:

```
DOCKER-USER
  ├─ from a Docker subnet?            → RETURN  (container traffic is Docker's business)
  ├─ RELATED,ESTABLISHED?             → RETURN
  ├─ heading into a Docker subnet?    → jump ufw-user-input   ← your ufw rules
  └─ nothing matched                  → DROP    (mirrors "default deny incoming")
```

Host-level filtering is **unchanged** — `INPUT` still works exactly as before. Verified:
with `ufw allow 22` removed, SSH from a non-permitted source is refused while
container ports behave per their own rules.

## Install

```bash
git clone https://github.com/archous-networks/ufw-docker.git
cd ufw-docker
sudo ./ufw-docker.sh install
sudo ./ufw-docker.sh status
```

Then use ufw normally:

```bash
sudo ufw allow 443/tcp
sudo ufw deny 8089/tcp
sudo ufw allow from 10.0.0.0/8 to any port 8089 proto tcp
```

Undo with `sudo ./ufw-docker.sh remove`.

## Install `ufw-rescue` first

**Do this before anything else, especially on a remote host.**

```bash
sudo install -m 0755 ufw-rescue /usr/local/sbin/ufw-rescue
```

If the firewall ends up in a bad state, from the console:

```bash
sudo ufw-rescue          # strip the stanza, rebuild ufw, verify
sudo ufw-rescue --open   # last resort: firewall OFF, you are definitely back in
```

It restores SSH **first**, before any cleanup, and keeps a snapshot of the broken state
in `/var/backups/ufw-rescue-<timestamp>/`.

## Two things that will bite you

### Ports are matched AFTER DNAT

By the time `DOCKER-USER` sees a packet, Docker has already rewritten the destination.
The rule therefore matches the **container** port, not the published one:

| published | ufw rule that works |
|---|---|
| `443:443` | `ufw allow 443` ✅ |
| `8443:443` | `ufw allow 443` — **not** `8443` ⚠️ |

The destination IP is also rewritten, so `ufw allow to <host-ip> port 443` never matches.
Use port-only or source-based rules.

### Host and container rules share one namespace

`ufw allow 22` opens 22 on the host *and* on any container publishing 22. You cannot
express "SSH to the host but never to a container". For most deployments that is fine —
know it before you rely on it.

## IPv6

Handled. `install` writes a matching stanza to `after6.rules` jumping to `ufw6-user-input`,
but **only when Docker actually has IPv6 networks** — otherwise there is nothing to filter.

`status` fails loudly if Docker has v6 networks and the v6 side is not wired, because a
v4-only setup that looks complete is worse than none.

## Requirements

Debian/Ubuntu with `ufw`, Docker, `iptables`, and root. Tested on Debian 12 with
ufw 0.36.2, Docker 28.x, nftables-backed iptables 1.8.9.

## Testing

```bash
sudo apt-get install -y bats
sudo HOST_IP=<this host's ip> bats tests/ufw-docker.bats
```

**These tests mutate the live firewall.** Run them on a disposable VM or in CI, never on
anything you care about. `teardown_file` always calls `ufw-rescue`, so a failing test
cannot leave the host unreachable.

## License

MIT — see [LICENSE](LICENSE).
