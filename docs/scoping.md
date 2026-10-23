# Which rules reach the host, and which reach containers

The short version: **the destination address is the only discriminator.** A rule with no
destination applies to both; a rule with one applies to exactly one.

This matters most when a host service and a container use the **same port number**.

## Measured

These numbers come from the suite, not from reasoning — `destination scopes a rule to the host or to a container, not both` in
`tests/ufw-docker.bats`, which runs on every push. The ports below are the ones
that test actually drives, so the claim is checkable rather than illustrative.

A host service and a container both on port 19101 — the container publishing `19100:19101`,
so both are reachable and both end up matching on `--dport 19101`:

| rule | host:19101 | container (via 19100) |
|---|---|---|
| *(none)* | `000` | `000` |
| `ufw allow 19101/tcp` | **200** | **200** |
| `ufw allow to <HOST ip> port 19101` | **200** | `000` |
| `ufw allow to <CONTAINER ip> port 19101` | `000` | **200** |

Clean separation, in both directions.

## Why

The two paths have different destinations by the time a rule is evaluated:

```
host service      client ──▶ host:19101 ─────────────────▶ INPUT     dst = HOST ip
container         client ──▶ host:19100 ──DNAT──▶ ctr:19101 ─▶ FORWARD  dst = CONTAINER ip
```

A port-only rule names neither, so it is consulted on both paths and matches on both. Add
a destination and it can only match one.

## The hazard worth knowing

```bash
sudo ufw deny 80/tcp
```

That closes port 80 **on the host and on every container whose container port is 80** —
and in `ufw status` it looks like one ordinary rule. Someone shutting off one service can
take down several without any indication.

If you mean one of them, say which:

```bash
sudo ufw deny to 203.0.113.10 port 80 proto tcp    # the host only
sudo ufw deny to 172.20.0.10  port 80 proto tcp    # that container only
```

## Picking the right form

| you want | write |
|---|---|
| this port everywhere | `ufw allow 80/tcp` |
| the host only | `ufw allow to <host-ip> port 80 proto tcp` |
| one container only | `ufw allow to <container-ip> port 80 proto tcp` |
| one container, from one source | `ufw allow from 10.0.0.0/8 to <container-ip> port 80 proto tcp` |

Container addresses: `sudo ufw-docker containers`. Pin them with IPAM first, or they
change on recreate — see [per-container.md](per-container.md).

**Always the CONTAINER port**, never the published one. `18090:80` means `port 80`; a rule
naming `18090` is accepted, listed by `ufw status`, and matches nothing.

## Caveats on this page

- Measured with a single host address. A host with several addresses should behave the
  same way, since the match is on the destination in the packet, but that has **not** been
  tested here.
- `--network host` containers share the host's namespace, so they are the host case.
