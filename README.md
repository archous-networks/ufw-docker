# ufw-docker

Make plain `ufw allow` and `ufw deny` actually govern **Docker-published ports**.

```bash
sudo ufw-docker install
sudo ufw deny 8089/tcp      # ...and this now genuinely closes it
```

## Not the same project as `chaifeng/ufw-docker`

There is an older, well-known project called
[`ufw-docker`](https://github.com/chaifeng/ufw-docker) by Chaiwat Suttipongsakul. **This is
not it, not a fork of it, and contains none of its code.** No file, line, or rule text was
copied or adapted from it. Everything here was derived from reading ufw's own source on a
running host (`/lib/ufw/ufw-init-functions`, `backend_iptables.py`) and testing against a
live firewall.

The two converge on the same hook because there is only one correct place to put these
rules — Docker documents `DOCKER-USER` precisely so people can filter container traffic.
Agreeing on that is not derivation.

Where they genuinely differ:

| | `chaifeng/ufw-docker` | this |
|---|---|---|
| ufw chain used | `ufw-user-forward` | `ufw-user-input` |
| how you write rules | its own CLI: `ufw-docker allow httpd 80/tcp` | plain `ufw allow 80/tcp` |
| targets | a named container | a port, as ufw always has |

Theirs is semantically tidier — forwarded traffic judged by forward rules — and it targets
container IPs, which sidesteps the remapped-port caveat below. It is also older and far
more widely deployed.

**Use theirs if your team will accept one new verb.** This exists for the case where that
is the sticking point: operators who already know `ufw` and should not have to learn
anything to firewall a Docker host.

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

**Install the rescue script first.** Especially on a remote host — it is what gets you
back in if anything goes wrong.

```bash
curl -fsSL https://raw.githubusercontent.com/archous-networks/ufw-docker/main/ufw-rescue \
  | sudo install -m 0755 /dev/stdin /usr/local/sbin/ufw-rescue
```

Then the tool itself:

```bash
curl -fsSL https://raw.githubusercontent.com/archous-networks/ufw-docker/main/ufw-docker \
  | sudo install -m 0755 /dev/stdin /usr/local/sbin/ufw-docker
```

Those two files are everything — there is nothing else to clone.

> **You are piping a script into `sudo`.** That is convenient and it is also exactly the
> pattern you should be suspicious of, particularly for something that rewrites your
> firewall. Read them first if that matters to you:
> ```bash
> curl -fsSL .../ufw-rescue | less
> ```
> Both are a few hundred lines of plain shell with no dependencies.

Wire it up:

```bash
sudo ufw-docker install
sudo ufw-docker status
```

Then use ufw exactly as you always have:

```bash
sudo ufw allow 443/tcp
sudo ufw deny 8089/tcp
sudo ufw allow from 10.0.0.0/8 to any port 8089 proto tcp
```

Undo with `sudo ufw-docker remove`.

## If something breaks

From the console:

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
