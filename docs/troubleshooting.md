# Troubleshooting

## My container port is blocked and I do not know why

```bash
sudo ufw-docker status
journalctl -k | grep 'UFW DOCKER BLOCK' | tail
```

The log line names the destination port **after DNAT** — the container port. If you
published `8443:443`, the rule you need is `ufw allow 443`. See
[caveats.md](caveats.md#ports-are-matched-after-dnat).

## My ufw rule has no effect on a container

| check | |
|---|---|
| Is the tool wired? | `ufw-docker status` — "IPv4 wired (N jumps…)" |
| Is it a remapped port? | use the **container** port |
| Is it a destination-IP rule? | those never match; use port or source |
| Is it a new Docker network? | look for `SUBNET DRIFT` below |
| Is it a `--network host` container? | ufw already governs it via INPUT |

## Subnet drift

```
SUBNET DRIFT — Docker networks not covered by the installed stanza:
        10.77.0.0/24
```

A network was created after `install`. Traffic to it is filtered by nothing.

```bash
sudo ufw-docker install      # re-derives subnets; safe to re-run
```

## `ufw reload` broke my firewall

Almost certainly the `before.init` hook is missing.

```bash
sudo ufw-docker status       # "before.init hook MISSING" is fatal
sudo ufw-docker rescue
sudo ufw-docker install
```

See [before-init.md](before-init.md).

## I cannot SSH in after a reboot

From the console:

```bash
sudo ufw-docker rescue
```

It restores SSH first, replaying your own restricted rule rather than opening the port.
Then check whether the self-heal unit should have caught it:

```bash
journalctl -t ufw-docker-selfheal -b
```

If it is not installed, `sudo ufw-docker install` enables it.

## `chain ... is incompatible, use 'nft' tool`

ufw's chains ended up in native nft syntax and iptables cannot touch them.

```bash
sudo ufw-docker rescue       # step 3b handles this
```

Note this message **also** appears for a chain that simply does not exist, so it is not by
itself evidence of a problem.

## `install` refused: "UNSUPPORTED ENVIRONMENT"

This is deliberate, and it is a refusal rather than a warning because the failure it
prevents is **silent**: `install` would succeed, `status` would report everything wired,
and nothing would be filtered.

```bash
sudo ufw-docker platforms     # the matrix, and where this host sits in it
```

Two kinds of check fail here:

| failure | meaning |
|---|---|
| `platform` | distro + major version + iptables backend match no row anything has proven |
| `mixed-backends` | rules exist in **both** iptables backends; the kernel evaluates both and a `DROP` in either wins |
| `swarm` | Swarm publishes through its own ingress mesh, a path this tool does not hook |
| `rootless` | rootless Docker publishes via a userspace proxy, so traffic never reaches `DOCKER-USER` |
| `ufw-paths` | ufw's rules files are not where ufw itself says they are |

**`mixed-backends` is the one to take seriously even though it sounds procedural.** It is
the hardest failure here to diagnose from outside, because everything looks correct and
traffic still does not flow — it is what made this project's own iptables-legacy CI leg
fail for days while the stanza it wrote was right the whole time. Fix it by rebooting
after a backend switch; see [operations.md](operations.md#changing-the-iptables-backend).

To install anyway:

```bash
sudo ufw-docker install --unsupported --force
```

Both flags are required — one flag is something you can paste from a forum post without
reading it. The fact is recorded in the stanza and reported by **every** `status` run
afterwards, because the person reading `status` is rarely the person who typed `--force`.

An accepted override **warns** and leaves `status` exiting 0. An environment that became
unsupported *after* install — somebody switched the backend — **goes red**, because that
is a change nobody agreed to.

## I want this in a monitoring check, not prose

```bash
ufw-docker status --json
```

Every check carries a stable `key`, so an alert names a condition instead of matching a
sentence that has changed wording several times in a single day.

```bash
# everything currently wrong, by name
ufw-docker status --json | jq -r '.checks[] | select(.level=="bad") | "\(.key): \(.message)"'

# the two that mean "filtering silently is not happening"
ufw-docker status --json | jq -e '.supported and (.checks[]|select(.key=="wired-v4").level=="ok")'
```

`bad` sets the exit code; `warn` is a thing to know, not a thing to page on.

## Wired, but is it actually filtering anything?

```bash
sudo ufw-docker status --counters
```

"Wired but filtering nothing" is the quietest failure in this design. A zero is **not**
reported as a fault — a quiet host is a normal host — so read the numbers yourself, and
remember they reset on every chain rebuild (`install`, `ufw reload`, the `before.init`
hook), not at boot.

## status exits non-zero — what does the code mean

| | |
|---|---|
| 0 | wired and healthy |
| 1 | something needs attention — drift, missing hook, half-built ufw, v6 unwired |

Suitable for cron:

```
*/30 * * * * root /usr/local/sbin/ufw-docker status >/dev/null || logger -t ufw-docker "needs attention"
```

## Which rules are actually deciding this?

```bash
sudo ufw-docker status --rules
```

Lists `ufw-user-forward` then `ufw-user-input` — the two chains, in the order consulted,
that every packet heading into a container is judged by. A rule with no destination
governs the host *and* containers; `-d <container ip>` governs that container alone; the
ports are container ports. → [operations.md](operations.md), [scoping.md](scoping.md)

## Who wired this host, and when?

```bash
sudo journalctl -t ufw-docker
```

One line per state-changing run. A `RESCUE invoked` line means somebody had to recover a
firewall that had gone wrong. → [logging.md](logging.md#the-audit-trail)

## I want to see what `install` would do before it does it

```bash
sudo ufw-docker install --dry-run
```

Prints the exact stanza and changes nothing. → [operations.md](operations.md)

## My container blocks are not being logged

Check whether ufw's own logging is on — ours is written to match it at install time, and
the two drift if you change one without re-running the other. `status` says which way:

```
ufw logging is ON but ours is OFF — re-run install to match
```

→ [logging.md](logging.md)

## Undoing everything

```bash
sudo ufw-docker remove              # preview
sudo ufw-docker remove --force      # do it
```

Your ufw rules are never touched — but they stop reaching containers. The preview says so,
and names the DENY rules that will stop closing container ports.
