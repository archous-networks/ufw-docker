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
chains, and checksums of every file in `/etc/ufw`. Neither half alone is enough: `user.rules`
can be correct while the chains are not, which is the whole failure mode `rescue` exists for.

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
