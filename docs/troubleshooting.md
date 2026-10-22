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
