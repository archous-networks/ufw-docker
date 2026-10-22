# Testing

```bash
sudo apt-get install -y bats
sudo HOST_IP=<this host's address> tests/run.sh
```

**Use `tests/run.sh`, never `bats` directly.**

> ### ⚠️ These tests mutate the live firewall
> Disposable VM or CI only. They enable and disable ufw, rewrite `/etc/ufw/*.rules`,
> restart the Docker daemon and recreate containers.

## Two rules, both learned by breaking a host

### 1. Nothing else may touch the firewall while they run

Not another run, not a manual `ufw-docker install`, not an `ufw` command in another shell.

This produced a *convincing, entirely fictitious* bug during development: a manual
disable/enable check run alongside a background suite showed the wiring lost **3 times out
of 3**, because the suite's teardown was stripping the stanza between the install and the
check. Run cleanly it is fine.

`tests/run.sh` holds `/var/lock/ufw-docker-tests`, so a second run refuses to start.

### 2. Do not kill the run

bats' `teardown_file` does not fire on SIGINT/SIGTERM, so a `pkill` mid-test left ufw
inactive with 6 of 11 logging chains and no SSH rule. `tests/run.sh` traps
`EXIT INT TERM` and runs `rescue` regardless.

If a run dies in a way that escapes even that (`SIGKILL`, power loss):

```bash
sudo ufw-docker rescue
```

## The probe must not be a container

`tests/netns-probe.sh` uses a network namespace on a veth pair.

A Docker container is the obvious choice and is **wrong**: the tool exempts every Docker
subnet as container-originated, so a container probe `RETURN`s before it is ever judged
and the test passes regardless of behaviour. A netns is not a Docker subnet, so its
traffic takes the same path an internet client's does.

## A flaky result here is usually contention

Two apparent flakes were investigated as real bugs. One was single-point sampling after an
async operation (the Docker restart test — 100 samples at 0.5 s across a real restart
never saw the rules missing). The other was the concurrency above.

**Before believing an intermittent failure, confirm nothing else is touching the
firewall**: `pgrep -f bats`, and check for the lock.

## The probe reports, it does not assert

`netns-probe.sh get` **always exits 0** and prints the HTTP code (`000` when blocked).

That is deliberate. curl exits 28 on timeout, which is the *expected* outcome for a
blocked port — and as a bare statement under bats' errexit it failed the test outright,
with a message (`failed with status 28`) that pointed at the probe rather than at what was
being measured. Tests that used `$(probe …)` inside a comparison were unaffected, so the
bug only appeared in the one test that called it for its side effect.

Keep that property: a measurement helper that can fail the suite by succeeding at
measuring a failure is a trap.

## Gotchas

- An apostrophe inside `${VAR:?...}` breaks bats' preprocessing with
  `unexpected EOF while looking for matching '`.
- CI must publish test ports **1:1**. A remapped `-p 8089:80` makes the "allow opens it"
  tests fail *and* the "blocked" tests pass vacuously — they would stay green even if the
  tool did nothing.
