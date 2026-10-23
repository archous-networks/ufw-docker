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

**It cannot run at all if the binary it names is not there.** `ExecStart` is
`/usr/local/sbin/ufw-docker selfheal`, which is where the documented install puts the
tool — but a host wired from a clone, or one where the binary was later moved, has a unit
that fails at every boot. `install` warns about that, once; **`status` now checks it on
every run**, and grades it red:

```
the self-heal unit calls /usr/local/sbin/ufw-docker, which is NOT executable — it fails at EVERY boot
    Nothing repairs this host unattended. Put the tool where the unit expects it:
    sudo install -m 0755 ./ufw-docker /usr/local/sbin/ufw-docker
```

A unit file present but **disabled** is graded the same way, for the same reason: the
host looks configured and nothing runs. Either enable it or remove it with
`install --no-selfheal`, so that nothing implies a recovery that is not there.

This was found by restarting a leg container's init. Before the check, such a host
printed *every* status line green — including `DOCKER-USER is reached from FORWARD` —
while the unit went `failed` and left the chain at zero jumps. The firewall was not
broken; the thing that repairs it was, and that is only discovered on the boot where it
was needed.

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
- **a real BAD boot → detected and repaired.** No longer the outstanding item:

  ```
  17:43:42  DOCKER-USER emptied after ufw applied the stanza
  17:43:42  ufw-docker-selfheal starts (sleeps 20s)
  17:44:02  "stanza installed but DOCKER-USER unwired - reloading ufw"
  17:44:06  finished — jumps: 3, status healthy
  ```

  Driven by `tests/cold-boot-check.sh`, which installs a one-shot unit ordered
  `After=docker.service Before=ufw-docker-selfheal.service` to recreate the ordering a
  late-starting Docker daemon produces.

- **the same thing, per push, on every distro in the matrix.** `tests/leg-coldboot.sh`
  arms that identical saboteur inside a leg and restarts the container's init — which
  re-runs every unit and re-evaluates ordering, because a leg runs systemd as pid 1. It
  asserts the unit *saw* the broken chain (`DOCKER-USER unwired`) rather than merely
  finding a healthy one, which is the distinction the hardware test learned the hard way.
  It is an init boot, not a kernel boot; `cold-boot-check.sh` is still the real thing.

**That run also validated the 20-second delay, which until then was a guess.** The chain
was emptied at boot and the unit caught it exactly twenty seconds later — so the delay is
what gives a Docker daemon starting after ufw time to do its damage *before* the unit
looks. Checking immediately would have found everything fine, every time, and the unit
would have been useless without ever appearing to be.

> An earlier attempt at this test reported PASS having exercised nothing: it emptied
> `DOCKER-USER` *before* rebooting, which proves nothing because that is runtime state
> and ufw rewires it from the stanza at boot. The unit logged `ufw healthy at boot` and
> the test counted the healthy firewall as proof of a repair. See
> [testing.md](testing.md).
