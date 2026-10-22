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
- CI must publish test ports **1:1**. A remapped `-p 8089:80` makes the "allow opens it"
  tests fail *and* the "blocked" tests pass vacuously — they would stay green even if the
  tool did nothing.

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
