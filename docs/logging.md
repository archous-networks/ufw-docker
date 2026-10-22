# Logging

## Blocked container traffic

Dropped by our chain, logged with its own prefix and rate-limited to 3/min — the same
limit ufw applies to its own blocks:

```
[UFW DOCKER BLOCK] IN=ens192 OUT=br-170139de947a SRC=203.0.113.9 DST=172.18.251.3 ... DPT=8089
```

```bash
journalctl -k | grep 'UFW DOCKER BLOCK'
```

A distinct prefix from ufw's `[UFW BLOCK]`, so container drops are distinguishable from
host drops at a glance.

### Why this exists

`-j DROP` was originally bare. ufw logged host blocks and said **nothing** about container
blocks — so "my container port is blocked and I do not know why" had no entry point in any
log, which is the opposite of what ufw sets you up to expect.

### Why our own chain and not `ufw-logging-deny`

ufw's own logging chain is populated by a later pass. Declaring it in `after.rules` (which
we must, to reference it) would **flush it** and silence ufw's own logging entirely. A
self-contained `ufw-docker-logging-deny` has no such dependency.

### Known divergence

`ufw logging off` does **not** silence it — our chain carries its own `LOG` rule. Tracked
in [`TODO.md`](../TODO.md) as C2.

## Everything else

| What | Where |
|---|---|
| self-heal decisions | `journalctl -t ufw-docker-selfheal` |
| what a self-heal repair did | `/var/log/ufw-docker-selfheal.log` |
| rescue snapshots of a broken firewall | `/var/backups/ufw-rescue-<timestamp>/` |
| `install` / `remove` / `status` | stdout only — no audit trail yet (`TODO.md` C1) |

## Counters

The chain counters answer "is anything actually being dropped":

```bash
sudo iptables -L DOCKER-USER -v -n --line-numbers
sudo iptables -L ufw-docker-logging-deny -v -n
```
