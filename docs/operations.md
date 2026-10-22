# Day-to-day operation

The commands you run after `install`, and what each one is actually for.

## Look before you leap: `install --dry-run`

`remove` previews by default and `install` did not, which was the wrong way round — of
the two, `install` is the one that rewrites your firewall. It now previews too:

```bash
sudo ufw-docker install --dry-run
```

It prints the Docker subnets it found, the **exact** stanza it would append to
`after.rules` (and `after6.rules`), whether it would write `before.init`, and whether it
would install the self-heal unit. Then it stops.

**Inert, and tested as inert.** A test snapshots `after.rules`, the `DOCKER-USER` chain
and `before.init` on both sides of the run and fails if any byte differs — asserting on
the output alone would still pass if the command had written the file.

Use it before the first install on a host you care about, and after creating a Docker
network, to see the subnets that would be picked up.

## The stanza is parsed before it is written

Every `install`, dry run or not, generates the stanza and runs it through
`iptables-restore --test` first. A stanza that does not parse is refused and **nothing is
written**.

This used to be found the hard way: `ufw reload` would fail, by which point `after.rules`
was already on disk and ufw was half-built, with only the rollback between the operator
and a lockout.

**What `--test` catches, and it depends on the backend:**

| rule | iptables-nft 1.8.9 | iptables-legacy |
|---|---|---|
| `-A TESTCHAIN --bogus` | ✅ rejected, rc=2 | ✅ rejected |
| `-A TESTCHAIN -j NOSUCHCHAIN` | ⚠️ **accepted**, rc=0 | ✅ rejected |

The nft row is measured on this project's development host; the legacy row is asserted by
the `iptables=legacy` CI leg. Under legacy the pre-write check is simply strictly
stronger.

So under nf_tables it is a syntax check, not a link check. The unresolvable-jump case is covered by
construction instead — the stanza declares every chain it jumps to, so it cannot name a
target it did not create. Both rows are pinned by a test, so the day a future iptables
changes its mind about either, the suite says so rather than the check quietly becoming a
no-op that still prints `stanza parses`.

## What is actually governing my containers: `status --rules`

`status` answers "are we wired". That is rarely the question. `--rules` answers the real
one:

```bash
sudo ufw-docker status --rules
```

```
rules containers are judged by, in order
  ufw-user-forward  (`ufw route ...`, consulted FIRST):
        (none)
  ufw-user-input    (plain `ufw allow|deny ...`, consulted SECOND):
        -A ufw-user-input -s 203.0.113.29/32 -p tcp -m tcp --dport 22 -j ACCEPT
```

Read it with three things in mind, which the command prints under the listing:

- a rule with **no destination** governs the host **and** every container;
- a rule with `-d <container ip>` governs **only** that container;
- the ports are **container** ports, not published ones.

See [Rule scoping](scoping.md) for the measured basis of the first two and
[Caveats](caveats.md) for the third.

Off by default because it is long: a host with a real rule set prints a lot, and `status`
is also what runs at the end of every `install`.

## Which version wired this host

```bash
ufw-docker --version
```

The stanza carries the version that wrote it, so `status` can compare the two and warn
when the binary has moved on:

```
wired by ufw-docker 0.9.0, but this binary is 0.10.0 — re-run install
```

That is the case that matters. A stanza written by an older version, under a newer
binary, is exactly what a confusing bug report looks like — and nothing else on the host
records it.

## The audit trail

Every state-changing run logs one line to syslog. See [Logging](logging.md#the-audit-trail).

```bash
sudo journalctl -t ufw-docker
```

## Backups

`install` backs up `after.rules` before touching it, and keeps the newest three.
`rescue` snapshots the broken state to `/var/backups/ufw-rescue-<timestamp>/`, same
policy.

`remove --force` leaves all of them alone, on the grounds that the moment you are undoing
a firewall change is a bad moment to also destroy the record of it. To clear them out
too:

```bash
sudo ufw-docker remove --force --include-backups
```

**It still keeps one** — the backup that run itself took, immediately before stripping
the stanza. Same reasoning: wiping the history and the only copy of the state you just
left in a single command is not a thing anyone wants, even when they asked for it.

`--include-backups` without `--force` is refused outright. All three behaviours are
covered by a test.

## When to re-run `install`

It is idempotent — it strips its own stanza and rewrites it — so re-running is always
safe. Do it after:

| event | why |
|---|---|
| creating or removing a Docker network | subnets are frozen at install time; `status` flags the drift |
| `ufw logging on` / `ufw logging off` | our logging is baked into the stanza |
| upgrading `ufw-docker` itself | so the stanza matches the binary |

`status` reports all three, so the honest answer to "when" is: whenever `status` tells
you to.
