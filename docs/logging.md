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

### It follows `ufw logging`, but only at install time

Our chain has its own `LOG` rule, so nothing about `ufw logging off` reaches it
automatically. `install` therefore reads ufw's setting and writes the stanza to match:
logging on → the `LOG` rule is there; logging off → it is replaced by a comment saying so.

**The two drift the moment you change ufw's setting without re-running `install`.** That
is the honest limit of a static stanza, so `status` compares them and says which way they
have diverged:

```
ufw logging is OFF but ours is still ON — re-run install to match
ufw logging is ON but ours is OFF — re-run install to match
```

Both directions are covered by a test. Re-run `ufw-docker install` after any
`ufw logging on|off`.

## Everything else

| What | Where |
|---|---|
| self-heal decisions | `journalctl -t ufw-docker-selfheal` |
| what a self-heal repair did | `/var/log/ufw-docker-selfheal.log` |
| rescue snapshots of a broken firewall | `/var/backups/ufw-rescue-<timestamp>/` |
| `install` / `remove` / `rescue` | `journalctl -t ufw-docker` — see below |

## The audit trail

Every state-changing run writes one line to syslog, tagged `ufw-docker`:

```bash
sudo journalctl -t ufw-docker
```

```
install starting (version 0.9.0, v4='172.17.0.0/16 172.18.251.0/25 ')
install complete and verified (version 0.9.0)
remove invoked (--force)
RESCUE invoked () — the firewall was in a state somebody had to recover from
rescue finished rc=0 (snapshot /var/backups/ufw-rescue-20261022005726)
```

This exists so "who wired this host, and when" has an answer. A `rescue` line is the one
worth alerting on: it means somebody had to recover a firewall that had gone wrong.

`status`, `containers` and `install --dry-run` write nothing — they change nothing.

Deliberately best-effort: a host without `logger` loses the trail rather than the run.

## Counters

The chain counters answer "is anything actually being dropped":

```bash
sudo iptables -L DOCKER-USER -v -n --line-numbers
sudo iptables -L ufw-docker-logging-deny -v -n
```
