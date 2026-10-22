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

## Destination-IP rules never match

```bash
ufw allow to 203.0.113.10 port 443     # will NOT work for a container
```

The destination has been rewritten to the container's address before we see it. Use
port-only or source-based rules.

## Host and container rules share one namespace

`ufw allow 22` opens 22 on the host **and** on any container publishing 22. There is no
way to express "SSH to the host, never to a container".

This is the direct cost of jumping into `ufw-user-input` — which is also the entire point
of the tool, since it is what makes the commands you already know apply to containers. If
you need that separation, `chaifeng/ufw-docker` targets container IPs instead.

## `--network host` containers are unaffected

They share the host's network namespace, so their traffic is `INPUT`, not `FORWARD`.
Ordinary ufw rules already govern them — correctly, and without this tool.

## IPv6 needs daemon support to matter

With a v6-enabled Docker *network* but a daemon lacking `ip6tables`, Docker installs its
own `raw`/PREROUTING drop for inbound traffic to container v6 addresses, **ahead of
FORWARD**:

```
DROP  !br-xxxx  ->  fd00:dead:beef::2
```

Our v6 stanza is written and applied correctly but never consulted. It becomes live only
with `"ipv6": true, "ip6tables": true` in `daemon.json`.

`status` reports v6 as not wired when Docker has no v6 networks, and **fails** if Docker
has them and we are not wired — a v4-only setup that looks complete is worse than none.

## Subnets are frozen at install time

A Docker network created after `install` is covered by nothing. `status` detects this and
exits non-zero:

```
SUBNET DRIFT — Docker networks not covered by the installed stanza:
        10.77.0.0/24
    traffic to these is filtered by nothing. Re-run: ufw-docker install
```

Worth running `status` from cron for exactly this reason.

## Swarm, overlay and rootless Docker are untested

Overlay/ingress networking and rootless Docker (slirp4netns) take different paths. Nothing
here is known to work there.
