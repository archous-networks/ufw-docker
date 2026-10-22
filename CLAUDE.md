# ufw-docker — development notes

Everything here was verified on a live Debian 12 host (ufw 0.36.2, Docker 28.x,
iptables 1.8.9 nftables backend). Where a claim came from reading rather than running,
it says so.

## The mechanism, and why this chain

`FORWARD` on a Docker host, in order:

```
-A FORWARD -j DOCKER-USER        <- runs FIRST; Docker's documented hook, left alone by Docker
-A FORWARD -j DOCKER-FORWARD
-A FORWARD -j ufw-before-forward
...
```

`DOCKER-USER` runs before Docker's own accept rules, which is why a `DROP` there wins.

`chaifeng/ufw-docker` jumps to **`ufw-user-forward`**, which is semantically tidier
(forwarded traffic judged by forward rules) but only reachable via `ufw route allow …`.
We jump to **`ufw-user-input`** instead, because the requirement was that operators keep
using the commands they already know. That is the only real difference between the two
projects; the hook and the stanza shape are the same.

## before.init is load-bearing, not a nicety

**Without it the firewall breaks on the second `ufw reload`.** Measured, not theorised:

| | reload #1 | reload #2 |
|---|---|---|
| ufw | active | **DOWN** |
| logging chains | 11 | **6** |
| SSH rule in `ufw-user-input` | present | **GONE** |

Mechanism: ufw deletes and recreates its own chains on every apply. Once our stanza has
run, `DOCKER-USER` references `ufw-user-input`, and iptables refuses to delete a chain
another chain references — `CHAIN_DEL failed (Device or resource busy)`. ufw aborts
part-way and leaves a half-built firewall. The host stays reachable only on existing
conntrack entries; every new SSH connection is refused.

`before.init` runs at `ufw-init-functions:125`, and `delete_chains` at `:145/:173` — so
emptying `DOCKER-USER` in the hook releases the references just in time. `after.rules`
repopulates it later in the same run, so there is no window where Docker traffic is
unfiltered while ufw is up.

## ufw's file order (the other thing that surprised us)

```
288:  before.rules    restored 1st
303:  after.rules     restored 2nd    <- our stanza; ufw-user-input does NOT exist yet
343:  user.rules      restored 3rd    <- the operator's rules, including SSH
```

Two consequences:

1. The stanza **must** declare `:ufw-user-input - [0:0]`, or the restore fails with
   `Chain 'ufw-user-input' does not exist`.
2. That declaration flushes the chain — which is **safe only because of this ordering**.
   `user.rules` repopulates it afterwards. If the order were reversed it would delete the
   operator's SSH rule.

⚠️ **Never apply the stanza with a manual `iptables-restore`.** Out of band, step 3 never
runs, the flush is permanent, and the SSH allow is gone. This is exactly how the firewall
got broken during development.

## Subnets are derived, never hardcoded

An early draft used `! -d 172.16.0.0/12`. Wrong: a user-defined network can sit on `10.x`
or `192.168.x` and would be silently dropped. `subnets()` reads them from
`docker network inspect` at install time.

Interface names are **not** usable as the handle — `br-<id>` is derived from the network
id and changes when a network is recreated. Source/destination subnet is stable.

## What survives what

| event | survives? | notes |
|---|---|---|
| `ufw reload` ×5 | ✅ | only with `before.init`; rule count stays constant |
| `ufw disable` → `enable` | ✅ | |
| `docker compose up --force-recreate` | ✅ | |
| `systemctl restart docker` | ✅ | Docker creates `DOCKER-USER` only if absent; it does not flush it |
| host reboot | **untested** | see below |

**Reboot is the remaining gap.** `ufw-docker-selfheal.service` was written as a net —
it waits 20s after boot, checks for an SSH rule in `ufw-user-input`, and runs `ufw-rescue`
if missing — but a real reboot has not been performed. Do it on a disposable VM before
claiming boot-ordering safety.

## Testing

Bats (`apt-get install bats`, 1.8.2 on Debian 12 — no vendoring needed).

**The probe must not be a Docker container.** The tool exempts every Docker subnet as
container-originated, so a container probe `RETURN`s before it is judged and the test
passes regardless. `tests/netns-probe.sh` uses a network namespace on a veth pair, which
is not a Docker subnet, so its traffic takes the same path an internet client's does.

`teardown_file` always calls `ufw-rescue`. Non-negotiable: a failing test must never leave
the host unreachable.

Gotcha hit while writing the suite: an apostrophe inside `${VAR:?...}` ("this host's")
breaks bats' preprocessing with `unexpected EOF while looking for matching '`.

## The nft-incompatible chain failure

Hit for real at the end of a full test run. `iptables` started refusing to touch ufw's
chains:

```
iptables v1.8.9 (nf_tables): chain `ufw-user-input' in table `filter' is incompatible, use 'nft' tool.
```

The rules were all still there — visible via `nft` — but expressed in **native nft
syntax** (`tcp dport 22 accept`) rather than the form iptables-nft emits
(`meta l4proto tcp tcp dport 22`). The compat layer will not read a chain it did not
write, so every `iptables -F` / `-X` in the rescue path silently did nothing and ufw
could not rebuild.

Recovery requires clearing the chains through `nft`, which also means deleting the
base-chain jump rules by handle first — a referenced chain cannot be removed.
`ufw-rescue` step 3b does this, and it runs **before** the iptables teardown so the
teardown has something it can actually act on.

Two details worth keeping:

- **Detect the specific error string.** An absent chain also makes `iptables -S` fail,
  and a first version treated that as incompatibility — sending a perfectly healthy host
  down the nft-destruction path. A rescue script must never take drastic action on a
  false positive.
- The root cause of the syntax divergence is **not established**. It appeared during a
  bats run that interleaved `ufw-rescue`'s `iptables -F/-X` with ufw's own rebuild. If
  you can reproduce it deterministically, write it down here.

## Still open

- **Reboot/boot-ordering**, above.
- **Functional IPv6.** The v6 stanza is verified to generate and apply (`IPv6 wired (1
  jumps into ufw6-user-input)`), but the dev host has no global IPv6, so no v6 packet has
  ever been filtered by it. Needs a v6-capable host.
- **Port remapping.** `8443:443` requires the operator to write `443`. Fixable only by
  translating ufw's rules into `DOCKER-USER` with `--ctorigdstport` — a tool, not a
  stanza. Not attempted.
