# Caveats

Things that are true and will surprise you. None of these are bugs; they follow from
where the hook sits.

## Ports are matched AFTER DNAT

By the time `DOCKER-USER` sees a packet, Docker has rewritten the destination. The rule
therefore matches the **container** port, not the published one:

| published | the rule that works |
|---|---|
| `443:443` | `ufw allow 443` ✅ |
| `8443:443` | `ufw allow 443` — **not** `8443` ⚠️ |

Pinned by a test so it cannot regress silently. Fixing it properly would mean translating
ufw's rules into `DOCKER-USER` with `--ctorigdstport`, which is a resident translator
rather than a static stanza.

## Destination-IP rules match the CONTAINER, not the host

```bash
ufw allow to 203.0.113.10 port 443     # ❌ the HOST's address — never matches
ufw allow to 172.20.0.10  port 80      # ✅ the CONTAINER's address — works
```

The destination is rewritten to the container's address before we see it, so naming the
host address cannot work. Naming the **container** address can, and is a useful
capability rather than a limitation — see [per-container.md](per-container.md).

Pair it with a static IPAM address, or the rule stops matching when the container is
recreated.

## A PORT-ONLY rule applies to the host and to containers

`ufw allow 22` opens 22 on the host **and** on any container whose container port is 22.
One rule, two effects, and `ufw status` shows nothing unusual.

That is the cost of jumping into `ufw-user-input` — which is also the point of the tool,
since it is what makes the commands you already know apply to containers.

**It is not a hard limitation.** The destination address separates them cleanly, measured:

| rule | host | container |
|---|---|---|
| `ufw allow 19101/tcp` | open | open |
| `ufw allow to <host-ip> port 19101` | open | **closed** |
| `ufw allow to <container-ip> port 19101` | **closed** | open |

Full detail, and the `ufw deny 80` hazard, in [scoping.md](scoping.md).

## `--network host` containers are unaffected — and are now listed

They share the host's network namespace, so their traffic is `INPUT`, not `FORWARD`.
Ordinary ufw rules already govern them — correctly, and without this tool.

The problem was never the behaviour, it was the **presentation**. Those containers have
no address of their own, so `ufw-docker containers` dropped them entirely: you could not
see the thing you could not target, and the natural conclusion was that this tool had
silently missed them. They are now listed in their own section:

```
on the HOST network — not governed by ufw-docker
    prometheus-node-exporter

These share the host's network namespace, so they have no address of
their own and 'ufw allow to <ip>' can never target them.

That is not a gap: their traffic arrives on INPUT like any host
service, so your ORDINARY ufw rules already govern them —
'ufw allow 8080/tcp' works on these exactly as you would expect.
```

**Note the wording, which is deliberate: "not governed by ufw-docker", never
"unsupported".** These containers work correctly. Swarm, a rootless-ONLY daemon, Docker's
nftables firewall backend and a mixed iptables backend are *unsupported* — the preflight
refuses to install on them. (A rootless daemon alongside a rootful one is a third case:
supported, and now named in `status` — see below.) Spending
that word on something harmless is exactly how it stops being read in the cases where it
means real danger, so host-network containers do **not** trip the preflight.

## IPv6 needs daemon support to matter

With a v6-enabled Docker *network* but a daemon lacking `ip6tables`, Docker installs its
own `raw`/PREROUTING drop for inbound traffic to container v6 addresses, **ahead of
FORWARD**:

```
DROP  !br-xxxx  ->  fd00:dead:beef::2
```

Our v6 stanza is written and applied correctly but never consulted. It becomes live only
with `"ipv6": true, "ip6tables": true` in `daemon.json`.

**Both halves of that are now measured.** Enabling the daemon flags makes Docker's
`raw`/PREROUTING DROP disappear — it existed *only* because the daemon lacked
`ip6tables` — and the v6 stanza takes over. With it on, IPv6 behaves exactly like IPv4:

| rule | v6 probe |
|---|---|
| none | `000` blocked |
| `ufw allow 19200/tcp` | `200` |
| `ufw deny 19200/tcp` | `000` |
| `ufw allow to <container v6> port 19200` | `200` |
| `ufw allow from <client v6> to any port 19200` | `200` |
| `ufw allow from <a different v6> …` | `000` |

CI runs the whole suite **twice**, with daemon `ip6tables` off and on, because the two
legs exercise different code and both are real deployments. See [testing.md](testing.md).

`status` reports v6 as not wired when Docker has no v6 networks, and **fails** if Docker
has them and we are not wired — a v4-only setup that looks complete is worse than none.

> ⚠️ **Testing v6 by hand: bind the listener to `::`.** `python -m http.server` binds
> `0.0.0.0` only, so a v6 probe of it gets a TCP RST and returns `000` — identical to a
> correctly blocked port. That cost a real debugging round here: the firewall was working
> the entire time and the service was not listening.

## ufw's own `IPV6=no` makes the v6 stanza dead text

There are **two** IPv6 switches, and they fail differently. The section above is about
Docker's. This one is about ufw's, in `/etc/default/ufw`:

```
IPV6=no
```

With that set, ufw never loads `after6.rules` at all and never creates `ufw6-user-input`.
So the v6 stanza is written correctly, parses correctly, and **is never read** — while
Docker happily forwards v6 into containers.

The combination is not exotic. `IPV6=no` is a common hardening default on hosts that
believe they are v4-only, and Docker acquires v6 networks later, when someone enables
`"ipv6": true` for one compose stack.

**`status` used to report only the symptom** — *"Docker has IPv6 networks but IPv6 is NOT
wired"* — which is true, and leaves the operator to guess. The obvious response is to
re-run `install`, which cannot possibly help: ufw will not read the file either time.

It is now named:

```
[BAD] Docker has IPv6 networks but ufw has IPV6=no in /etc/default/ufw — ufw never loads
      after6.rules, so our IPv6 stanza is dead text and v6 INTO CONTAINERS IS UNFILTERED
      -> Re-running install will not fix this; ufw has to be doing v6 first:
             sudo sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
             sudo ufw reload && sudo ufw-docker install
```

`install` warns about the same thing at the moment it writes the stanza, and writes it
anyway — it costs nothing and becomes live the instant the switch is flipped.

> An unreadable or absent `/etc/default/ufw` is treated as **enabled**, because that is
> ufw's own default and because the failure that must never happen is a false all-clear
> about v6. Reporting "enabled" keeps the v6 checks live; reporting "disabled" would
> silence them.

## Subnets are frozen at install time

A Docker network created after `install` is covered by nothing. `status` detects this and
exits non-zero:

```
SUBNET DRIFT — Docker networks not covered by the installed stanza:
        10.77.0.0/24
    traffic to these is filtered by nothing. Re-run: ufw-docker install
```

Worth running `status` from cron for exactly this reason.

## The untested cases below are now REFUSED, not merely documented

Everything in this file used to be a caveat you had to read. Swarm, a rootless-only
daemon, **Docker's nftables firewall backend**, a mixed iptables backend, a `DOCKER-USER`
that `FORWARD` does not reach, ufw's files not being where ufw says, and any platform the
matrix does not cover are now **preflight failures**: `install` refuses, and `status`
reports them on every run. A caveat in a document protects nobody who has not read it.

> This used to say "a non-nf_tables backend" was itself a failure. **It is not, and the
> standalone check that said so is gone.** iptables-legacy is supported and has its own
> CI leg per distro; the backend is one of the three fields the platform matrix matches
> on, so an unproven *combination* is refused while a proven legacy host installs
> normally. Keeping both the hardcoded rule and the matrix column was two answers to one
> question, and they disagreed within hours of being written.

`--unsupported --force` overrides it, loudly and permanently — see the README.

Note what is deliberately *not* a preflight failure: `--network host` containers. They
are understood, correctly unaffected, and governed by plain ufw `INPUT` rules. Calling
that "unsupported" would spend the word on something harmless, and then it would not be
read in the cases where it means real danger.

## macvlan and ipvlan networks are not governed — and are now excluded

A `macvlan` or `ipvlan` container talks to the LAN through the parent interface directly.
Its traffic never traverses `FORWARD`, so it never reaches `DOCKER-USER`, so **no rule on
this host applies to it** — not ufw's and not ours. Filter it upstream.

The behaviour worth knowing about is what we do with the **subnet**. `subnets()` used to
take every network's IPAM range regardless of driver, which on a macvlan network sitting
on a real LAN would have put this at the very top of `FORWARD`:

```
-A DOCKER-USER -s 192.168.1.0/24 -j RETURN                   # exempts the whole LAN
-A DOCKER-USER -d 192.168.1.0/24 -j ufw-user-input           # judges the whole LAN
-A DOCKER-USER -d 192.168.1.0/24 -j ufw-docker-logging-deny  # and drops what did not match
```

An entire real network exempted from forward filtering in one direction and default-denied
in the other, for containers this tool cannot govern anyway — all of the hazard and none
of the benefit. **Only `bridge` networks go into the stanza now**, and anything excluded is
listed by `status` and `ufw-docker containers` rather than silently dropped.

An allowlist, not a denylist: an unknown third-party driver is exactly the case where
guessing is wrong.

## `ufw default allow incoming` does not extend to containers

ufw expresses its default policy as the **policy on the built-in chain**, not as a
terminal rule inside `ufw-user-input` — and our jump enters `ufw-user-input` directly, so
the default is never consulted on the container path. Unmatched container traffic falls
through to `ufw-docker-logging-deny` and is dropped.

So on an allow-incoming host, **installing this tool takes every published container port
from open to closed**, with nothing in `ufw status` explaining why. `install` warns before
it writes, and `status` keeps saying so.

That asymmetry is defensible — default-deny for forwarded traffic is the whole point — but
it is a real behaviour change at install time, and it is an outage if nobody said so first.

## Swarm is NOT supported — do not assume it works

**Untested, deliberately, and not on the roadmap.** This is a statement of scope, not a
gap waiting to be filled: an untested claim of support is worse than a stated limitation.

`subnets()` would pick up an overlay network's subnet, so `install` will appear to
succeed and `status` will report everything wired. That tells you nothing, because Swarm
does not take the packet path this tool hooks:

| | |
|---|---|
| `docker_gwbridge` | external access, bridge-like — *might* behave, untested |
| `ingress` | published Swarm ports route through the routing mesh with IPVS load balancing, not plain DNAT. `DOCKER-USER` may not sit in that path at all |

So the dangerous outcome is the familiar one: **wired-looking and filtering nothing**, for
exactly the services you most wanted filtered. `status` cannot detect this and will not
warn you.

If you need Swarm, verify it yourself on a disposable host with the probe matrix in
[testing.md](testing.md) before trusting any of it. Treat a pass as evidence about your
Docker version and topology, not as support.

## Rootless Docker — tested now, and the expectation was half wrong

This used to say "almost certainly unsupported; nothing here has been run against it."
It has been run against it now: a real rootless daemon stood up beside a rootful one in
a Debian 12 leg, publishing a port, on every push (`tests/leg-rootless.sh`).

**A rootless published port is a userspace listener on the host, not a DNAT.** That one
fact decides everything else:

| | |
|---|---|
| does its traffic reach `DOCKER-USER`? | **No.** It arrives on `INPUT`, like any host service. Measured: zero rules in `iptables-save` mention the published port. |
| is it therefore unprotected? | **No** — and this is where the old guess was wrong. Ordinary ufw governs it. `ufw deny 18099/tcp` blocks it outright; verified both ways in the leg. |
| does this tool govern it? | **No.** Nothing in the stanza applies. |
| did this tool *say* so? | **It did not, and that was the real defect.** `ufw-docker containers` printed an EMPTY table on a host with a rootless container publishing a port, and `status` was silent. An operator auditing exposure with this tool got a clean bill of health for an open port. |

`status` and `containers` now both name any rootless daemon they find, and say which
rules do govern it. Two differences from the bridge containers this tool exists for, and
both are easy to get backwards:

- **name the PUBLISHED port**, not the container port — the exact opposite of the rule
  for a bridge container, where `-p 8443:443` means you write `ufw allow 443`;
- **ufw's default policy applies to them.** Bridge containers are default-deny whatever
  the host policy says, because our jump enters `ufw-user-input` directly. Rootless ports
  are not. On a `default allow incoming` host the two behave oppositely.

A **rootless-only** host is still a preflight refusal: `docker info` reports rootless, no
published port traverses `DOCKER-USER`, and there is nothing for the stanza to do. What
is newly handled is the mixed case — rootless *alongside* rootful — where the tool wires
the rootful daemon correctly and now says plainly that the other one is not its business.

## Docker's nftables firewall backend has no DOCKER-USER at all

**The one setting that removes the foundation this tool is built on.** Docker is growing
a native nftables backend, selected with `"firewall-backend": "nftables"` in
`daemon.json` and reported by `docker info` as `FirewallBackend.Driver` since API 1.49.

This is not inference. moby's own `setupUserChains()` opens with:

```go
// There's no equivalent to DOCKER-USER in the nftables implementation.
if nftables.Enabled() {
    return
}
```

So the chain is never created, `FORWARD` never jumps to it, and every rule this tool
writes would sit in a chain that does not exist.

**`install` refuses and `status` reports it**, naming the backend. The reachability check
would have caught the symptom — no jump from `FORWARD` — but it would have blamed a
third-party firewall flushing the chain, sending an operator to look for something that
is not there.

There is no workaround beyond `"firewall-backend": "iptables"`. If Docker ever makes
nftables the default, this tool needs a second implementation, not a patch.
