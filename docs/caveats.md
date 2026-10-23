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
"unsupported".** These containers work correctly. Swarm, rootless Docker and a mixed
iptables backend are *unsupported* — the preflight refuses to install on them. Spending
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

Everything in this file used to be a caveat you had to read. Swarm, rootless Docker, a
mixed iptables backend, ufw's files not being where ufw says, and any platform the
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

## Rootless Docker is untested

Rootless Docker uses slirp4netns, not these chains. Almost certainly unsupported; nothing
here has been run against it.
