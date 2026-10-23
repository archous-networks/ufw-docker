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

**What `--test` catches — and the second row is a property of the iptables VERSION, not
of the backend:**

| rule | iptables-nft | iptables-legacy |
|---|---|---|
| `-A TESTCHAIN --bogus` | ✅ rejected, rc=2 | ✅ rejected |
| `-A TESTCHAIN -j NOSUCHCHAIN` | **version-dependent** — see below | ✅ rejected |

Syntax is always caught; that half is universal and is asserted outright.

The unresolvable jump is not, and it is not even a clean split by backend. 1.8.9 and
1.8.10 in nft mode **accept** it (rc=0); **1.8.2 rejects it**, exactly as legacy does.

> This table used to read "nf_tables: accepted, rc=0", measured on one host and stated as
> a property of the backend. The Debian 10 leg disproved it on its first run — and failed
> a test that was asserting the measurement rather than the guarantee. It is a property of
> an iptables version we do not control, so the suite now **records** what it observes here
> and asserts the guarantee separately.

**The guarantee is that the stanza never jumps to a chain it does not declare**, and that
is now a test (`the stanza never jumps to a chain it does not declare`) rather than a
comment claiming it is true by construction. It parses the generated stanza, collects
every `-j` target, and fails on any that is neither a kernel builtin nor declared by the
stanza itself. That is what makes the blind spot harmless, so it is the thing worth
enforcing — and where `--test` does catch the jump, the pre-write check is simply
strictly stronger.

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

## Monitoring: `status --json`

The exit code is all monitoring used to get — "something is wrong", never *what*.
Anything richer meant scraping coloured prose, which changed wording several times in a
single day.

```bash
ufw-docker status --json
```

```json
{
  "version": "0.9.0",
  "healthy": true,
  "installed": true,
  "supported": true,
  "preflight_failed": [],
  "installed_unsupported": "",
  "ufw_dir": "/etc/ufw",
  "ufw_paths_derived": true,
  "checks": [
    {"key": "wired-v4", "level": "ok", "message": "IPv4 wired (3 jumps into ufw-user-input)"}
  ]
}
```

Each check carries a stable `key`, so an alert can name the condition it cares about
rather than matching on a sentence:

```bash
# everything currently wrong, by name
ufw-docker status --json | jq -r '.checks[] | select(.level=="bad") | "\(.key): \(.message)"'

# the two that mean "filtering silently is not happening"
ufw-docker status --json | jq -e '.supported and (.checks[]|select(.key=="wired-v4").level=="ok")'
```

`level` is one of `ok`, `warn`, `bad`, `info`. **`bad` is what sets the exit code**;
`warn` is a thing to know, not a thing to page on.

`status --counters` adds `DOCKER-USER` packet counts to the human-readable form —
the cheapest signal of *wired but filtering nothing*. See [logging.md](logging.md).

Two fields deserve attention:

- **`supported`** — whether this host passes the preflight *right now*. A host can stop
  being supported without anyone touching this tool, by switching the iptables backend.
- **`installed_unsupported`** — non-empty if somebody installed with
  `--unsupported --force`, listing which checks were failing at the time. It is read
  from the stanza, so it survives the binary being replaced.

Together they encode the grading rule: if a current failure was *already accepted* at
install time, `status` warns and still exits 0. If it was not, something changed
underneath the install and `status` exits 1.

### Why the output is built before it is printed

`status` collects every check into one list and then renders it, as text or as JSON,
rather than printing as it goes. That is not tidiness: two copies of a check drift, and
this project has already shipped three assertions that passed for the wrong reason.
One source of truth, two views. It also means check messages carry no colour codes —
colour is added at render time — which is what makes them safe to put in JSON.

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

## Updating to a new version

```bash
curl -fsSL https://github.com/archous-networks/ufw-docker/releases/latest/download/ufw-docker \
  | sudo install -m 0755 /dev/stdin /usr/local/sbin/ufw-docker
sudo ufw-docker install        # <- not optional
```

`install` refreshes all three pieces of installed state — the stanza, `before.init` if
we manage it, and the self-heal unit — then reloads and verifies.

**The trap: curling the new binary without re-running `install` leaves a new binary
enforcing the old version's stanza.** Nothing breaks loudly; the firewall keeps working
exactly as the previous version wired it, while `--version` reports the new one. That is
why the stanza records the version that wrote it, and why `status` says:

```
wired by ufw-docker 0.9.0, but this binary is 1.0.0 — re-run install
```

The gap between the two commands is safe. The old stanza keeps filtering the whole time;
nothing is torn down until `install` succeeds, and it rolls back if the result is
unhealthy.

Verify the download first — see [releases.md](releases.md).

## Changing the iptables backend

Switching between `iptables-nft` and `iptables-legacy` is not just changing the
alternative. **Rules already in the old backend stay there, and the kernel evaluates
both** — so a `DROP` left behind in the one you walked away from still wins over an
`ACCEPT` in the one you moved to. That is the single hardest failure here to diagnose
from the outside, because `status` reports everything correctly wired and traffic still
does not flow.

It is not hypothetical: this is exactly what made the project's iptables-legacy CI leg
fail for days while the stanza it was writing was correct the whole time.

```bash
sudo ufw-docker remove --force                              # 1. unwind our stanza
sudo update-alternatives --set iptables  /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
sudo reboot                                                 # 2. the guaranteed-clean step
sudo ufw-docker install                                     # 3. rewire
```

**Step 2 is the one people skip.** `remove` unwinds *our* stanza, but Docker's own
chains, ufw's chains and anything else stay in the old backend. A reboot is the only
step that reliably clears both subsystems. If you genuinely cannot reboot,
`nft flush ruleset` followed by `systemctl restart docker` achieves the same thing for
the nft side — that is what CI does — but a reboot is what to do on a host you care
about.

X1's **mixed-backend check is the other half of this procedure**: it refuses to install
when rules exist in both subsystems, which is precisely what skipping step 2 leaves
behind. The check and this procedure are one thing described from two directions.

## `remove` leaves the binary

Deliberately. Reinstalling is the likely next step, and `rescue` has to stay reachable
exactly when you have just unwound the firewall. The preview says so:

```
WOULD LEAVE:
  - /usr/local/sbin/ufw-docker itself  ('rescue' stays available; --purge --force to delete it)
```

To remove it too:

```bash
sudo ufw-docker remove --force --purge
```

`--purge` requires `--force`, and is orthogonal to `--include-backups` so the two
compose. The deletion happens from an `EXIT` trap rather than inline: bash reads a
script incrementally as it runs, so deleting the file mid-execution can leave the
interpreter reading garbage off the freed inode.
