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
creates it but never writes rules of its own into it. (Up to Docker 28 it seeded the
chain with a single `-j RETURN`; **Docker 29 leaves it genuinely empty**. Same effect —
an empty chain falls through — but do not key anything on finding that RETURN.) We fill
it in:

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

## It refuses environments it has not been proven on

Before writing anything, `install` runs a preflight and **refuses** where this tool has
never been verified. That is a refusal rather than a warning because the failure it
guards is silent: `install` would succeed, `status` would report everything wired, and
nothing would be filtered. Nobody would learn otherwise until something reached a port
it should not have.

Two kinds of check. The **platform matrix** (distro + major version + iptables backend)
must match a row that real evidence put there — a green CI leg, or a full suite run on a
host of that class. Every row is backed by a leg that runs the whole suite inside that
actual distribution on every push (`tests/container-leg.sh`), so "proven" means proven
this commit, not proven once by hand. And four **mechanism** checks that fail regardless of platform:
rules present in *both* iptables backends, Docker Swarm, rootless Docker, and ufw's
files not being where ufw says they are.

`--unsupported --force` overrides it, and the fact is baked into the stanza so every
later `status` says so.

→ [supported.md](supported.md), and `ufw-docker platforms`

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
chain rather than clobbering it.

**That adoption is by design, not luck**, and moby says so in the source. `setupUserChain()`
in `daemon/libnetwork/firewall_linux.go`:

> This chain allows users to configure firewall policies in a way that persist daemon
> operations/restarts. The daemon does not delete or modify any pre-existing rules from
> the `DOCKER-USER` filter chain.

The code matches the comment, at v26.1.4, v28.0.0 and master:

| call | behaviour | why it matters here |
|---|---|---|
| `NewChain` | `-n -L` first, `-N` only if absent | **never flushes** a populated chain |
| `AddReturnRule` | appends a bare `-j RETURN` if none exists | lands after our rules, harmless — and **removed on master**, which is why Docker 29 creates the chain empty |
| `EnsureJumpRule` | `-D` the existing jump, then `-I` at position 1 | re-asserts `DOCKER-USER` **first in FORWARD** on every daemon start and every firewall reload |

That last row is the useful one: Docker actively re-hooks the chain rather than merely
leaving it alone, which is why the wiring survives a reload. It also means a brief window
on each restart where the jump is absent — the reason `status` checks reachability
separately from chain contents.

> **One backend removes all of this.** With `"firewall-backend": "nftables"` in
> `daemon.json`, moby's `setupUserChains()` returns immediately — *"There's no equivalent
> to DOCKER-USER in the nftables implementation."* No chain, no jump, nothing for this
> design to attach to. `install` refuses; see [caveats.md](caveats.md).
