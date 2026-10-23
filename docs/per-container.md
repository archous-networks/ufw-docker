# Per-container rules

You can target an individual container, not just a port. This works **today, with no
extra tooling** — it just needs the container to have a predictable address.

## Why it works

By the time `DOCKER-USER` runs, Docker's DNAT has already rewritten the destination to the
**container's** address. So a ufw rule naming that address matches:

```bash
sudo ufw allow to 172.20.0.10 port 80 proto tcp
```

```
-A ufw-user-input -d 172.20.0.10/32 -p tcp --dport 80 -j ACCEPT
```

Verified with two containers on the same network, both publishing container port 80:

| | published | rule | result |
|---|---|---|---|
| `capp` 172.20.0.10 | 18080 | `allow to 172.20.0.10 port 80` | **200** |
| `cdb` 172.20.0.11 | 18081 | *(none)* | **000** |

Same container port, different container, correctly unaffected. `deny` works the same way.

> This is the thing the port-only model cannot express: *this port, on this container
> only*, instead of the port being open on every container that publishes it.

## Give the container a stable address

Dynamic addresses change on recreate and your rule silently stops matching the container
it was written for. Pin them with Docker's IPAM — which needs a user-defined network with
a subnet; the default bridge will not do:

```yaml
services:
  web:
    networks:
      app:
        ipv4_address: 172.20.0.10
networks:
  app:
    ipam:
      config:
        - subnet: 172.20.0.0/24
```

```bash
docker run -d --network app --ip 172.20.0.10 ...
```

Verified: with a static address, deleting and recreating the container leaves the rule
still matching.

## Verified rule forms

All measured on a live host, two containers on one network both publishing container
port 80 (`vt1` → `172.21.0.10` via `18090:80`, `vt2` → `172.21.0.11` via `18091:80`),
probed from outside.

| command | emitted rule | result |
|---|---|---|
| `ufw allow to 172.21.0.10 port 80 proto tcp` | `-d 172.21.0.10/32 --dport 80 -j ACCEPT` | **vt1 open, vt2 closed** |
| `ufw allow from 10.97.0.0/24 to 172.21.0.10 port 80 proto tcp` | `-s 10.97.0.0/24 -d 172.21.0.10/32 --dport 80` | **open from that source** |
| …same, from a different source | as above | **closed**, correctly |
| `ufw route allow to 172.21.0.10 port 80 proto tcp` | into `ufw-user-forward` | **open** |
| `ufw deny to 172.21.0.11 port 80 proto tcp` | `-d 172.21.0.11/32 --dport 80 -j DROP` | **that container closed, neighbour unaffected** |

So source, destination and `ufw route` all compose the way you would expect.

## The published port is the one trap

```bash
# container publishes 18090:80
sudo ufw allow to 172.21.0.10 port 80     # ✅  works
sudo ufw allow to 172.21.0.10 port 18090  # ⚠️  accepted, listed, matches nothing
```

The published port **only exists before DNAT**:

```
client ──▶ host:18090 ──DNAT──▶ 172.21.0.10:80 ──▶ FORWARD ──▶ these rules
                                            ▲
                           by here the dport is 80, not 18090
```

Nothing warns you. ufw says `Rule added`, lists it in `ufw status`, and emits
`--dport 18090` into the chain — where no packet ever has that destination port.
Measured: the port stays closed.

This is the most likely mistake to make, because **18090 is the number you know** — it is
in your compose file and your browser URL. `80` is an internal detail of the container.

It only bites when the two differ. With `443:443` they are identical and nobody notices.

## Remember the port is the CONTAINER port

```bash
# published 18080:80
sudo ufw allow to 172.20.0.10 port 80     # ✅  container port
sudo ufw allow to 172.20.0.10 port 18080  # ❌  published port, never matches
```

Same reason as everywhere else — see [caveats.md](caveats.md#ports-are-matched-after-dnat).

## Re-run install after adding a network

A network created after `install` is covered by nothing. `ufw-docker status` detects that
and exits non-zero; `ufw-docker install` fixes it.

## What is NOT possible

**Naming a container in the rule.** iptables matches addresses, not names, so anything
name-based is really *resolve name → address*, and the only question is when:

| | handles a changed IP | cost |
|---|---|---|
| resolve when the rule is written | no — you re-run the tool | none |
| **static IPAM address** (above) | nothing to handle | you manage addresses |
| `ipset` + a `docker events` watcher | yes, live | a resident process |

The watcher is the only option that tracks dynamic addresses, and it means shipping a
daemon. Deferred as **A3** in [`FUTURE.md`](../FUTURE.md) rather than built.
