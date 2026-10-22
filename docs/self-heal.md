# The self-heal service

A systemd unit that checks the firewall 20 s after boot and repairs it if it came up
wrong. **On by default**; `install --no-selfheal` opts out.

## Why it is on by default

Boot ordering between `ufw` and `docker` is the one thing this design cannot fully
control, and its failure mode is the worst one: ufw starts half-built, the SSH allow is
missing, and the host needs console access to recover.

It shipped opt-in briefly, argued as "a destructive repair run unattended". That was
wrong. It fires only when this is false:

```sh
iptables -S ufw-user-input | grep -q -- '--dport'
```

That is a host with **no user rules at all** — already unreachable. There is no healthy
state it can damage, and the alternative is somebody driving to a console. A default
should be the safe one, and safe here means "you can still log in".

`--no-selfheal` exists for hosts whose boot-time state belongs to config management or an
immutable image, where an unexpected unit is the bigger surprise.

## What it checks

Two symptoms, deliberately narrow:

| Symptom | Meaning | Action |
|---|---|---|
| `ufw-user-input` has no rules | ufw came up half-built; host unreachable | `ufw-docker rescue` |
| stanza installed but `DOCKER-USER` has no jumps | container ports unfiltered while everything *looks* fine | `ufw reload` |

The second is the canary for a future Docker that flushes `DOCKER-USER` on startup instead
of adopting it. That failure has no symptom anywhere else: ufw active, rules listed,
nothing in any log, and containers wide open.

Anything broader risks running a destructive rebuild over a merely unusual state.

## What it does NOT do

**It does not re-install after a rescue.** `rescue` strips the stanza by design — its job
is a working ufw, not a wired one — so after a repair the host is reachable but
**unfiltered**. The unit says so:

```
RECOVERED but UNWIRED: ufw rules no longer affect Docker ports - run 'ufw-docker install'
```

Auto-reinstalling would be a loop if the stanza is what broke ufw in the first place. An
unfiltered host that says so beats one that flaps.

## Reading it

```bash
journalctl -t ufw-docker-selfheal          # what it decided
cat /var/log/ufw-docker-selfheal.log       # what a repair actually did
```

The logic is `ufw-docker selfheal`, a normal subcommand, not a shell one-liner inside
`ExecStart` — so it can be read, tested and fixed like anything else. Run it by hand with
`SELFHEAL_DELAY=0` to skip the boot wait.

## Verified

- healthy boot → `ufw healthy at boot`, nothing changed
- `DOCKER-USER` emptied → rewired, 0 → 3 jumps
- `ufw-user-input` emptied → SSH restored **restricted, not blanket**, no leftovers
- a real reboot → ordering confirmed, no intervention needed

Not yet verified: the unit performing a repair during an actual bad boot. Its detection
has run at boot and `rescue` is well exercised by hand, but no boot has gone wrong.
