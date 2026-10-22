# Architecture

How the pieces fit, and why each one exists. Start here.

## The problem, precisely

Docker publishes a port by DNAT in `nat/PREROUTING`, then the packet is **forwarded** to
the container. ufw filters `INPUT`. Forwarded traffic never traverses `INPUT`, so a ufw
rule about a published port has no effect — while `ufw status` reports it as though it
does.

```
internet ──▶ PREROUTING (DNAT: 203.0.113.1:443 → 172.18.251.3:443)
                 │
                 ▼
             FORWARD ───▶ DOCKER-USER ───▶ DOCKER-FORWARD ───▶ container
                              ▲
                              └── this is the only hook Docker gives us
```

`INPUT`, where every ufw rule lives, is not on that path.

## What we insert

`DOCKER-USER` is Docker's documented hook: it runs **first** in `FORWARD`, and Docker
creates it but never writes to it. We fill it in:

```
DOCKER-USER
 ├─ -s <each docker subnet>     → RETURN      container-originated: Docker's business
 ├─ -m conntrack ESTABLISHED    → RETURN      replies to permitted traffic
 ├─ -d <subnet> → ufw-user-forward            `ufw route allow …`  (more specific verb)
 ├─ -d <subnet> → ufw-user-input              `ufw allow …`        (what people type)
 └─ -d <subnet> → ufw-docker-logging-deny     log, then drop
```

Everything after the first two lines only applies to traffic heading **into** a container
network from somewhere else — which is exactly the traffic ufw could not previously see.

Precedence is deliberate: `ufw route` rules win over plain `ufw` rules, because `route` is
ufw's own verb for forwarded traffic and therefore the more specific statement.

## Where each piece lives

| Piece | Lives in | Detail |
|---|---|---|
| the stanza | `/etc/ufw/after.rules`, `/etc/ufw/after6.rules` | [after-rules.md](after-rules.md) |
| the reload hook | `/etc/ufw/before.init` | [before-init.md](before-init.md) |
| boot repair | `ufw-docker-selfheal.service` | [self-heal.md](self-heal.md) |
| break-glass | `ufw-docker rescue` | [rescue.md](rescue.md) |
| drop logging | `ufw-docker-logging-deny` chain | [logging.md](logging.md) |

## Why ufw-user-input and not ufw-user-forward alone

`chaifeng/ufw-docker` jumps only to `ufw-user-forward`, which is semantically tidier —
forwarded traffic judged by forward rules. It needs its own CLI as a result, because
`ufw route` cannot express "this container, this port".

This tool jumps to **both**, input second, so that the command an operator already knows
(`ufw allow 443`) does what they expect. That is the entire reason this exists; everything
else follows from it. The cost is [a shared namespace](caveats.md#host-and-container-rules-share-one-namespace).

## Boot ordering

Measured on a real reboot:

```
[ 3.66s]  ufw.service finished
[ 8.12s]  docker.service started
[28.16s]  ufw-docker-selfheal finished  → "ufw healthy at boot"
```

ufw runs **before** Docker. So `DOCKER-USER` does not exist when `after.rules` is applied —
our `:DOCKER-USER - [0:0]` creates it, and Docker then starts and adopts the populated
chain rather than clobbering it. That adoption is verified empirically across both a
daemon restart and a cold boot, but is [not known to be contractual](../TODO.md).
