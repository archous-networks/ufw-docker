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

## Negative assertions pass for the wrong reason

Most assertions in this suite are negative — "this port is blocked". A blocked port and a
port with **nothing listening** both return `000`, so any environmental breakage turns
those tests into passes-for-free while looking perfectly green.

This has happened twice, both only visible in CI:

- **A remapped published port.** `-p 8089:80` means the rule must name the *container*
  port, so `ufw allow 8089` could never match. The "allow opens it" tests failed; the
  "blocked" tests passed vacuously.
- **A dead container.** One test restarts the Docker daemon, which stops a container with
  no restart policy and removes its DNAT rule. Later tests probed a port with nothing
  behind it. Invisible locally, where UISP's containers are `restart: always`.

`ensure_service` now checks from the host that something is actually listening before any
assertion about the firewall, and **skips loudly** rather than passing. When adding a
negative assertion here, ask what else produces the same observation.

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
- The suite must publish its test port **1:1**. A remapped `-p 19089:80` makes the "allow
  opens it" tests fail *and* the "blocked" tests pass vacuously — they would stay green
  even if the tool did nothing. This is why `start_testsvc()` publishes `19089:19089`.

## The distro matrix — real distributions, in containers

```bash
tests/container-leg.sh debian:12 nft        # one leg, the same command CI runs
tests/container-leg.sh ubuntu:22.04 legacy
```

Each leg boots a **real distribution with systemd as pid 1 and its own Docker daemon**
inside one privileged container, copies the working tree in, and runs the identical
suite. CI runs these legs with the identical script — there is no CI-only path through
it, which is deliberate: a behaviour that differs between CI and a developer's machine
is the exact shape of bug that has cost this project two cancelled runs.

### Why it exists

Before it, CI tested **one** environment: Ubuntu 24.04 with iptables 1.8.10, because that
is what a GitHub runner is. Nothing in the fleet runs that. Debian 12 / iptables 1.8.9
was verified only by a human running the suite by hand on one host — strong evidence, but
not per-push, so **a Debian-only regression reached `main` green**.

The blocker was believed to be "GitHub has no Debian runners", which is true, and was
taken to mean VMs, DinD services or self-hosted infrastructure. It does not.

### What each leg actually covers

| leg | ufw | iptables | docker.io |
|---|---|---|---|
| `debian:10` | 0.36 | **1.8.2** | 18.09.1 |
| `debian:11` | 0.36 | 1.8.7 | 20.10.5 |
| `debian:12` | 0.36.2 | **1.8.9** — the fleet's version | 20.10.24 |
| `ubuntu:22.04` | 0.36.1 | 1.8.7 | **29.1.3** |
| `ubuntu:24.04` | 0.36.2 | 1.8.10 | 29.1.3 |

× `{nft, legacy}`. The pairing matters as much as either axis: the daemon is the distro's
own, so an old iptables is tested beside the old Docker that ships with it — which is the
combination that exists in the wild. Ubuntu 22.04 is the useful outlier, pairing iptables
1.8.7 with a *modern* daemon.

### What is NOT real in there

Stated plainly because a matrix that overstates its reach is worse than a small one.

- **The kernel is the runner's**, shared by every leg. `debian:10` means Debian 10
  *userspace* on a 6.x kernel, not the 4.19 a real Debian 10 box runs. A distro whose own
  kernel lacks an nftables feature would not be caught here.
- **No cold boot.** The self-heal unit exists for a real machine coming up with ufw at
  ~3.7s and Docker at ~8.1s. A container cannot reproduce that; `tests/cold-boot-check.sh`
  on real hardware remains the only evidence, and it is still manual.
- **No real load.** A leg is a clean room with one container. The development host has
  sixteen and a live UISP stack, where `install` costs ~8s against ~1s here.
- **A non-initial network namespace is not a host**, and that is not a theoretical
  reservation — see the logging trap below.

So these legs are the **per-push gate**, and the host run is what you do before a release
and after anything that touches boot or self-heal. They do not retire it.

### Three traps, all of which produced a confident wrong answer first

**`--tmpfs /tmp` is `noexec`.** Several tests shadow `docker` with a stub on `PATH` to
simulate a Swarm host. `command -v docker` found the stub, and executing `docker` silently
ran the **real** one, because `command -v` checks the executable bit and the kernel checks
the mount. Four tests failed with no hint of a filesystem being involved. The leg mounts
`/tmp` with `exec` now, which is also what a real host has.

**`net.netfilter.nf_log_all_netns` defaults to 0.** Netfilter `LOG` calls reach the kernel
ring buffer **only from the initial network namespace**. So inside a leg the stanza's
`[UFW DOCKER BLOCK]` rule fires, the packet is correctly dropped, and *nothing is ever
logged*. It reads exactly like broken logging. It is a global sysctl that does not exist
inside the container's `/proc/sys` at all, so `container-leg.sh` sets it on the host and
puts it back afterwards.

**The kernel ring buffer is not namespaced.** Which means a leg's `journalctl -k` reads
the *host's* dmesg, including the host's own `[UFW DOCKER BLOCK]` lines. The logging test
used to grep for the prefix alone and would have passed on evidence it did not produce.
It now requires its own packet (`SRC=10.97.0.2 … DPT=19089`), and `container-leg.sh` takes
`/var/lock/ufw-docker-leg` so two legs cannot run side by side on one machine and pass on
each other's log lines. In CI each leg gets its own runner, so the lock never engages
there — it is for the developer running several by hand, which is precisely when it would
have been missed.

### It does not touch the host's firewall

Unlike `tests/run.sh`, this needs no `/etc/ufw-docker-tests-allowed` marker. Netfilter
state is **per network namespace**, and the container has its own — so a leg enabling ufw,
flushing chains and restarting a daemon is confined to it. Verified by running
`ufw-docker status` on the development host mid-leg: healthy and unchanged throughout.

Three things *are* host-wide, because they are not namespaced, and all three are named
rather than left to be discovered:

| | |
|---|---|
| `net.netfilter.nf_log_all_netns` | set to 1, **restored** afterwards |
| kernel modules (`ip_tables`, `ip6_tables`, …) | loaded on the host, **not unloaded**. A container has no `/lib/modules` for the running kernel, so it cannot load them itself, and ufw's `enable` dies without them. Unloading a module something else may be using is a real risk, and an unused table holds no rules, so it cannot change how anything is filtered |
| the kernel ring buffer | read only |

> The module one is worth dwelling on. It did not fail locally and failed every legacy
> leg in CI — because the development host already had `ip_tables` and `ip6_tables`
> loaded for its **own** ufw, so every local leg inherited a kernel that happened to be
> ready. "Works on the dev host" was load-bearing and completely invisible until a
> machine without that history ran the same script.

### A fourth trap, and the most interesting one

**Docker 29 creates `DOCKER-USER` empty.** Every earlier version added
`-A DOCKER-USER -j RETURN` when it made the chain. 29 does not. Nothing filters
differently — an empty chain falls through — but `rescue` writes that RETURN back as
"stock", so a suite run on Docker 29 *ends by reporting that it changed the host*, which
it had, and could not undo.

The fix is the general one rather than a special case: `snapshot_state` now records
`DOCKER-USER` per family and `restore_state` replays it verbatim. **The fingerprint was
covering something the restore did not** — the same shape of gap as the self-heal unit
above, caught the other way round. Whatever the fingerprint reads, the restore must be
able to put back.

> ⚠️ **Do not edit a script while it is running.** Bash reads a script by byte offset, so
> editing `container-leg.sh` mid-leg shifted the file under the running shell: it resumed
> mid-token (`line 184: he: command not found`) and re-ran the whole suite a second time.
> The run looked like a bizarre tool bug for several minutes. Let the leg finish.

## The IPv6 matrix

CI runs the whole suite **twice**: once with Docker's daemon `ip6tables` off, once on.
Both are real deployments and they exercise different code, so proving one proves half
the tool.

| leg | what it covers |
|---|---|
| `docker_ipv6: false` | the common production case. Docker installs its own `raw`/PREROUTING DROP ahead of FORWARD, so our v6 stanza is written but never consulted. `status` must report "no v6 networks; nothing to wire" and must **not** call that a fault |
| `docker_ipv6: true` | the v6 stanza actually decides. allow / deny / source-restricted / per-container-destination, all probed over IPv6 |

The two IPv6 tests each skip on the wrong leg, so the suite is honest about which one it
is running rather than silently covering less than it appears to.

To run the `true` leg locally:

```bash
sudo tee /etc/docker/daemon.json <<'JSON'
{ "ipv6": true, "ip6tables": true, "fixed-cidr-v6": "fd00:dead:beef::/64" }
JSON
sudo systemctl restart docker
sudo ufw-docker install        # pick up the new v6 subnet
```

**No global IPv6 on the host is required**, and this was set up on a host that has none.
The probe reaches the container through the *host end of a veth* — a ULA address that
Docker's DNAT rule (`! -i docker0 --dport N -j DNAT`) is happy to match, because it does
not care which of the host's addresses the client aimed at.

> ⚠️ **Bind the test listener to `::`.** `python -m http.server` binds `0.0.0.0` only. A
> v6 probe of a v4-only listener gets a TCP RST and returns `000` — indistinguishable
> from "correctly blocked", and it will look exactly like a firewall bug. It did.

> ⚠️ **`fd00:d0ck:...` is not a valid ULA.** `k` is not a hex digit, and dockerd refuses
> to start with an invalid `fixed-cidr-v6` — then systemd's restart limit keeps refusing
> even after the config is fixed, which reads like a second, different failure. It is
> not: `systemctl reset-failed docker.service` and start again.


## The suite refuses to run on an unmarked host

```
sudo touch /etc/ufw-docker-tests-allowed
```

Without it, `tests/run.sh` explains what it would do to the box and stops.

**This restricts the test suite, not the tool.** `ufw-docker` itself is *for* production
Docker hosts. The suite is a different matter: over a full run it restarts the Docker
daemon, flushes and rebuilds ufw's chains, and opens and closes ports.

A per-host marker rather than an environment variable, deliberately. The realistic
accident is not a user — deployments download the single `ufw-docker` file and never see
this directory. It is one of us running a familiar command in the wrong SSH session, and
an env var travels in shell history and muscle memory, which is exactly the failure. A
file does not travel.

It is also **not** a heuristic like "does this look like production". The development
host is a full UISP stack on purpose — that is why the container-recreate test runs there
and skips in CI. Any heuristic smart enough to refuse a customer's box would refuse the
most valuable test environment available.

## The host is returned to the state it was in

`rescue` guarantees a **working** firewall. It does not guarantee **this host's** firewall.
Those are different promises, and for a long time only the first was kept.

What the suite legitimately changed and never put back:

- **ufw-docker's install state.** `teardown_file` ends in `remove --force`, so a host that
  *had* the stanza installed was handed back without it. That is how the development host
  was found unwired.
- **Rules on ports the suite drives.** On a UISP box those are not spare ports. The
  remapped-port test used container port 443 and deleted `allow 443/tcp` on the way out —
  which is exactly how this host's UISP web UI went dark. That test now uses 19443.
- **ufw's enabled/disabled state**, and any files left behind in `/etc/ufw`.

The bats-level invariant (`rules-before` / `teardown_file`) only ever *reported* this
drift, and only for user rules. **Reporting is not restoring.** `tests/run.sh` now
snapshots the whole of `/etc/ufw` plus the enabled flag before the run, puts it all back
after, and then proves it by diffing a fingerprint taken before and after:

```
    [21:44:02] rescue finished
    [21:44:02] restoring this host's pre-suite state
    host state matches the pre-suite snapshot
    [21:44:09] restore finished
```

If the fingerprint does not match, the diff is printed, **the run exits non-zero**, and the
snapshot is kept with the two commands needed to put it back by hand.

The fingerprint covers declared *and* live state — `ufw status verbose`, both `DOCKER-USER`
chains, checksums of every file in `/etc/ufw`, **and the self-heal systemd unit plus whether
it is enabled**. Neither of the first two halves alone is enough: `user.rules` can be correct
while the chains are not, which is the whole failure mode `rescue` exists for.

> ⚠️ **The unit was missing from this list, and the restore reported success anyway.** Five
> consecutive runs printed `host state matches the pre-suite snapshot` while
> `ufw-docker-selfheal.service` was gone from the host, because a fingerprint cannot notice
> what it does not hash. It was found by asking "is this host ready to reboot?", not by any
> test. **If you give the suite the power to change something new, add it to `fingerprint()`
> in the same commit** — a restore that silently under-reports is worse than no restore,
> because it is believed.

**This runs in CI too, deliberately.** Making it local-only would leave the restore path
untested by the one thing that runs on every push, and a behaviour that differs between CI
and the development host is precisely the shape of bug that cost this project two cancelled
runs. `UFW_DOCKER_NO_RESTORE=1` skips it.

### The suite owns its service container, and its port

`ensure_service` only ever curls `127.0.0.1:<port>`, so whatever answers is what gets
tested. That port used to be **8089**, and the container was created by the **CI workflow**
rather than by the suite. Each half was a bug; together they were worse:

- On a UISP host `unms-nginx` publishes 8089, so a local run found the **operator's own
  service**, probed that instead of a container the suite controls, and then deleted their
  `ufw` rule for it. That is not a hypothetical — it took this host's UISP device endpoint
  down mid-run, and the invariant reported it 34 times in one run.
- Because only CI created the container, a local run had nothing of its own to fall back
  to. The divergence is what let the first problem hide.

Both are fixed by the same change: `setup_file` creates the container itself, on **19089**,
and the CI step is gone. CI and local now exercise the identical path, and the container is
removed afterwards only if the suite created it.

**Choosing a replacement port is a judgement, not a lookup**: it must be high, and not
something a real service plausibly listens on. Every port in `TEST_PORTS` is a port the
suite will *delete a rule for*, which is the whole reason this matters.

## The one test that cannot be automated: a real cold boot

The self-heal unit is verified in almost every respect by the suite — systemd drives it
against a genuinely broken firewall, it repairs it, it restores a *restricted* SSH rule
rather than a blanket one, it logs what it did, it leaves a healthy firewall alone, and
its enablement and `After=`/`Wants=` ordering are asserted declaratively.

**All of that happens on a running host.** The thing the unit exists for is the boot
race — ufw, Docker and this unit coming up in the right order on a cold start — and the
only honest way to test a boot race is to boot. So that part is currently verified *by
declaration*, not by observation, and the difference is exactly the kind this project
tries not to paper over.

`tests/cold-boot-check.sh` makes it two commands with a reboot between them. It is
deliberately **not** part of the suite: nothing should reboot a host as a side effect of
running tests.

```bash
sudo tests/cold-boot-check.sh arm      # breaks DOCKER-USER, on purpose
sudo reboot
sudo tests/cold-boot-check.sh verify   # did the unit put it back?
```

### Why the obvious way to break it does not work

The first version of this simply emptied `DOCKER-USER` and rebooted. **It reported PASS
having exercised nothing**, and the only reason that was caught is that the self-heal
unit's log line said `ufw healthy at boot`.

`DOCKER-USER` is **runtime state, not configuration**. At boot ufw starts, applies
`after.rules`, and the stanza in it rewires the chain — so the damage is undone by the
very reboot it was supposed to survive, long before the self-heal unit looks. The unit
found a healthy firewall, correctly did nothing, and the test counted the healthy
firewall as proof that the unit had fixed it.

The condition the unit actually exists for is: **ufw applies the stanza, and then
something flushes `DOCKER-USER` afterwards** — which is exactly what a Docker daemon
starting after ufw does. So `arm` now installs a one-shot saboteur unit ordered
`After=docker.service` and `Before=ufw-docker-selfheal.service`, which recreates that
ordering on the next boot and nothing else.

Consequences for how it behaves:

- **`arm` changes nothing immediately.** Your firewall is untouched until the reboot.
- On the next boot, Docker-published ports are unfiltered for the seconds between the
  saboteur firing and the unit repairing — and if the unit does *not* repair, they stay
  that way until you run `install`. That is the finding the test exists to get.
- SSH is never affected; it arrives on `INPUT`.
- `sudo tests/cold-boot-check.sh disarm` cancels before rebooting, and `verify` removes
  the saboteur whether it passed or failed — a test fixture that survives the test is a
  trap for the next boot.

`verify` demands positive evidence and reports **INCONCLUSIVE**, never PASS, when it does
not have it:

- the saboteur did not run → nothing was broken, so nothing was proven;
- self-heal logged `healthy at boot` → something else repaired it first and the unit's
  repair path was not exercised (this is precisely the trap above);
- only `stanza installed but DOCKER-USER unwired` counts as a pass.

It also refuses to pass if `/proc/sys/kernel/random/boot_id` is unchanged — "survived a
reboot" without a reboot is the purest form of a test that passes for the wrong reason,
and this suite has now shipped four of those.

**And it reads the right journal tag.** `cmd_selfheal` logs as `ufw-docker-selfheal`, not
`ufw-docker`; the first version grepped the latter, printed "No entries", and hid the one
piece of evidence that mattered.

A failure here is a *finding*, not an inconvenience: it would mean the unit's ordering is
wrong on a real boot, which is the single scenario it was written for.

## The operator's rules are an enforced invariant

Every test is measured against a baseline snapshot of `/etc/ufw/user.rules` taken in
`setup_file`, and the per-test `teardown` fails the test that violates it:

| | |
|---|---|
| **a deleted rule** | always a failure. No test has any business removing a rule the operator put there |
| **an added rule** | a failure unless it names a port or address the suite owns (`TEST_PORTS` / `TEST_ADDRS`) |
| **anything left at the end** | `teardown_file` compares exactly, before it unwinds anything |

This is the mechanical form of what used to be discipline, and discipline lost twice —
once leaking a blanket SSH rule onto a restricted host, once deleting CI's SSH rule.
**The check never asks what the host's rules look like, only whether they still look the
same**, so the two environments are free to differ. They differ in several ways besides
the SSH rule: UISP present or absent, 15 containers versus 1, three Docker networks
versus one.

## Two bats traps that cost CI runs

Both were diagnosed from CI logs and then reproduced locally. Worth knowing before
adding a test.

### A background process must close fd 3, or bats hangs

bats blocks on exit until every process holding its **fd 3** has exited. A background
process inherits it, so a long-lived one hangs the whole run — after the last test has
already reported.

Measured:

```
sleep 25 >/dev/null 2>&1 &        ->  bats exits after 25s
sleep 25 >/dev/null 2>&1 3>&- &   ->  bats exits immediately
```

**Redirecting stdout and stderr is not enough.** Both host listeners in this suite
already did that and still hung the run.

In CI the symptom was: all 35 TAP lines printed, then the job sat at *Run the suite* for
the full 25-minute timeout and was cancelled — which also threw away the post-failure
diagnostics that would have explained the original failure. The trigger was a test
failing *before* its `kill` line, leaving `python -m http.server` running forever.

Use `start_host_listener` / `stop_host_listeners`, which close fd 3 and record the PID so
`teardown` can kill anything a failed test did not.

### Diagnostics must go to fd 3, or you will never see them

The mirror image. bats captures a test's stdout and stderr, and `--tap` does not replay
them. A helper that printed its diagnostics to stderr on failure ran in CI and produced
**nothing** in the log. Print to `>&3`, which bats passes through to the terminal.

## Never delete the host's SSH rule to prove a point

Test 14 once ran `ufw delete allow 22/tcp` and restored it only if `setup_file` had been
the one to add it. That is two different questions conflated into one:

- *did we add it?* — governs whether re-adding it would **widen** the operator's exposure
- *did we delete it?* — governs whether we have to **put it back**

In CI the workflow adds `allow 22/tcp` before the suite, so the first answer was "no",
the delete still succeeded, and the rule was gone for the rest of the run. Downstream,
`status` reported no SSH rule, every `install` exited non-zero, `install`'s own health
check rolled the stanza back out, and eleven tests failed for a reason none of them had
anything to do with.

It was invisible locally by luck: the dev host's rule is `allow from <ip> to any port 22`,
which `ufw delete allow 22/tcp` does not match, so the delete quietly did nothing.

**A firewall suite has no business deleting the SSH rule of the box it runs on** to prove
something any port can prove. It uses its own port now, and a per-test `teardown` fails
the test that leaves `ufw-user-input` without an SSH rule — so the cause is named rather
than its victims.
