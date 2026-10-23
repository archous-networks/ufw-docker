# FUTURE — deferred, with the reason

Triaged 2026-10-22 alongside [TODO.md](TODO.md). Everything here was reviewed and
deliberately deferred. Nothing is here because we ran out of time to think about it.

Each entry says **what would bring it forward**, because "later" without a trigger is
just a way of never deciding.

---

## H2 · Is Docker's preservation of `DOCKER-USER` contractual? — **ANSWERED**
**S1 · [verified, from moby's source] · resolved 2026-10-23**

Answered by reading moby rather than by another experiment. `setupUserChain()` in
`daemon/libnetwork/firewall_linux.go` (and `libnetwork/firewall_linux.go` before the
tree was reorganised) carries this, in moby's own words:

```go
// This chain allows users to configure firewall policies in a way that
// persist daemon operations/restarts. The daemon does not delete or modify
// any pre-existing rules from the DOCKER-USER filter chain.
//
// Once the DOCKER-USER chain is created, the daemon does not remove it when
// IPTableForwarding is disabled, because it contains rules configured by user
// that are beyond the daemon's control.
```

**That is a stated intent, not an accident**, and the code matches it. Checked at
v26.1.4, v28.0.0 and master:

| call | what it actually does | consequence for us |
|---|---|---|
| `NewChain(userChain, Filter)` | `-n -L` first; `-N` only if absent | **never flushes.** A populated chain survives. |
| `AddReturnRule(userChain)` | appends `-j RETURN` if no bare `-j RETURN` exists | appends at the END, after our rules. Harmless — and **gone in master**, which is why Docker 29 creates the chain empty. |
| `EnsureJumpRule("FORWARD", userChain)` | if the jump exists, `-D` it, then `-I` at position 1 | **deletes and re-inserts on every daemon start and every firewall reload.** Guarantees `DOCKER-USER` is first in FORWARD; also means a brief window where it is absent. |

So: preserved by design, re-hooked at the top on every reload, and documented as such in
the source. The tool's self-heal and reachability checks remain correct mitigations —
not for Docker clobbering the chain, which it does not do, but for the window above and
for third parties.

### The real finding, which is worse and was not the question

Docker is growing a **native nftables backend**. `setupUserChains()` on master opens:

```go
// There's no equivalent to DOCKER-USER in the nftables implementation.
if nftables.Enabled() { return }
```

With `"firewall-backend": "nftables"` in `daemon.json` **there is no `DOCKER-USER` chain
at all** — never created, never jumped to. The entire design is inert, and `status` would
have reported it as "something flushed FORWARD".

Now a **preflight refusal** naming the backend, read from `docker info`'s
`FirewallBackend.Driver` (API ≥ 1.49; empty on older daemons, which is correct — they
predate the backend). Classification is covered by `tests/firewall-backend-selftest.sh`,
as pure logic: the refusal path cannot be exercised in a leg, and an untested refusal
path is how a tool starts refusing hosts that were fine.

**New standing item:** if Docker ever makes nftables the default backend, this tool needs
a second implementation, not a patch. Watch the default, not the feature.

---

## A2b · Make `ufw allow 8443` work for a remapped port
**S2 · [verified] · plausible, but a different architecture**

Publish `8443:443` and the rule that works is `ufw allow 443`. Part one — `status` naming
rules that can never match — is **done**. Making the published port actually work means
matching pre-DNAT with `-m conntrack --ctorigdstport`, which in turn means generating
`DOCKER-USER` from ufw's rule set and keeping the two in sync.

**Why deferred:** that is a resident translator, not a static stanza. The static stanza is
what makes this tool auditable, survivable and inspectable with plain `iptables -S` — and
it is what lets `rescue` reason about the firewall at all. Trading that away to remove a
footgun we now warn about loudly is not obviously the right deal.

**Brings it forward:** evidence that the warning is not enough — operators hitting it
repeatedly despite being told.

---

## A3 · Target a container by name
**S2 · [verified] · possible feature**

iptables matches addresses, not names. Targeting by **address** works today, is verified
to survive a container recreate with static IPAM, and `ufw-docker containers` flags the
containers on dynamic addresses — the ones a rule cannot safely name.

**Why deferred:** closing the dynamic case needs an `ipset` per container plus a
`docker events` watcher keeping it populated. Same architectural trade as A2b: a resident
daemon. Static IPAM covers the real need and is documented.

**A cheaper middle ground, if wanted:** `status` could flag a rule whose destination no
running container holds any more — the same shape as the subnet-drift check, ~30 lines. It
does not give name-based rules, only drift detection after the fact.

**Brings it forward:** a deployment that genuinely cannot pin addresses.

---

## A9 · Rootless Docker — **DONE**, and the expectation was half wrong
**S2 · [verified] · closed 2026-10-23**

Stood up for real: a rootless daemon beside a rootful one in a Debian 12 leg, publishing
a port, asserted on every push by `tests/leg-rootless.sh`.

This entry predicted "the rootless containers are neither protected nor mentioned". One
half held, the other did not, and the wrong half changes the advice:

- **"not protected" — false.** A rootless published port is a *userspace listener on the
  host*, not a DNAT. Its traffic arrives on `INPUT`, so ordinary ufw governs it.
  Measured: zero rules in `iptables-save` mention the port, and `ufw deny <port>` blocks
  it outright.
- **"not mentioned" — true, and that was the actual defect.** `ufw-docker containers`
  printed an EMPTY table on a host with a rootless container publishing a port, and
  `status` said nothing at all. Someone auditing exposure with this tool read that as
  "nothing is listening here".

`status` and `containers` now name any rootless daemon and say which rules do govern it,
including the two traps: it is the **published** port, not the container port, and ufw's
**default policy** applies to them where it does not to bridge containers.

Detection takes two signals — a socket under `/run/user/*/`, and a non-root `dockerd`.
The second needs a PID-namespace filter: a container's processes are visible in the
host's `ps`, so a nested rootless daemon made the HOST claim one. Caught on the
development box, which reported `rspaeth` while the daemon was inside a test container.

Still refused: a **rootless-only** host, where nothing published traverses `DOCKER-USER`
and there is nothing for the stanza to do.

---

## A12 · Origin lockdown to a WAF's egress ranges
**S2 · [unknown]**

[`docs/waf.md`](docs/waf.md) argues that a WAF is worth nothing unless the origin is
unreachable except from the WAF — and that locking it down is this tool's job. The
mechanism that rests on (source-restricted allow on a container port) **is** tested. The
full arrangement has never been stood up against a live Cloudflare or AWS WAF.

Two separate risks: whether ~22 source rules in `ufw-user-input` behave and perform as
expected (likely fine, unmeasured); and that **the ranges rotate** with nothing here
tracking them, so a host can be locked to a stale list.

**Why deferred:** we have no WAF to test against. `docs/waf.md` already states this
honestly in its measured-vs-reasoned table, so the page does not claim more than we know.

**Brings it forward:** a customer putting a UISP instance behind Cloudflare or AWS WAF.

---

## X2 · Support for the other environments — **DONE**
**S2 · the other half of X1**

Moved out of "deferred" on 2026-10-22: the real CI matrix was built. It is kept here
rather than deleted because the *reasoning* about what is and is not covered is still
live, and because the kernel caveat below is a standing limitation, not a finished task.

| environment | status |
|---|---|
| iptables-legacy | **done.** A11 green; evidenced by run 39868550084, and now by a `legacy` leg per distro |
| Debian 10 / 11 / 12, Ubuntu 22.04 / 24.04 | **done.** `tests/container-leg.sh`, run per distro × backend on every push |
| rootless Docker | **done** — A9 above; a rootless daemon beside a rootful one, per push |
| Swarm | closed as out of scope — see `caveats.md` |

### What it turned out to cost

The blocker was recorded here as "no GitHub Debian runners", which is true and was read
as meaning VMs, DinD or self-hosted infrastructure. It meant none of those: a privileged
container with `systemd-sysv`, `--cgroupns=host` and dockerd inside gives a real init, a
real daemon, its own network namespace and **that distro's own iptables**. One day, as
estimated.

It paid for itself the same day, on the oldest leg:

- **a real portability bug** — `awk 'length(a)'` on an array, which Debian 10's mawk
  rejects outright, so SSH port detection silently fell through to guessing port 22 on
  every Debian 10 host. `rescue` depends on that detection.
- **Docker 18.09 cannot start on a cgroup v2 kernel at all** (`Devices cgroup isn't
  mounted`), so Debian 10's own `docker.io` is not a configuration that exists in the
  field — the leg uses docker-ce, which is what such a host must run.
- **iptables 1.8.2 prints `-p 6`, not `-p tcp`.** Anything matching rule text by protocol
  name reads an old host as having no rule.

### Two of the three standing limitations are now closed

This section used to list three things a leg could not cover: the kernel, cold boot and
real load. Two of them turned out to be assumptions rather than limits.

**Cold boot — now per push.** A leg runs systemd as pid 1, so `docker restart` is a
genuine init boot: every unit re-runs, ordering is re-evaluated, `/run` is a fresh
tmpfs. `tests/leg-coldboot.sh` arms the same saboteur `cold-boot-check.sh` uses —
ordered `After=docker.service Before=ufw-docker-selfheal.service` — restarts the init,
and asserts the unit saw the broken chain and repaired it.

What it still does not cover, and the script says so in its header: there is **no kernel
boot**. `/proc/sys/kernel/random/boot_id` is the runner's and does not change, which is
exactly why the freshness signal is `/run` and not `boot_id` — the obvious check would
have passed forever while testing nothing. No initramfs, no module load, no real NIC, so
anything depending on `network-online.target` against hardware is still untested.
`tests/cold-boot-check.sh` on real hardware remains the real thing.

**Real load — now per push.** `tests/leg-load.sh`, deliberately not a benchmark: a
throughput number from a container on a shared runner is noise, and a test that fails on
a busy runner teaches people to re-run until green. It asserts **correctness under
concurrency**, which is deterministic — 200 concurrent connections against a DENY must
all be refused, 200 against an ALLOW must all succeed, and the rule set must be
byte-identical afterwards. One leaked connection is a failure, and a leak is precisely
what a conntrack or ordering bug looks like: invisible one connection at a time.

### The one that is still open: the kernel is always the runner's

A leg is that distro's **userspace** on whatever kernel the runner boots. `debian:10`
is Debian 10 tooling on a 6.x kernel, not the 4.19 a real Debian 10 box runs. A failure
that needs the distro's own kernel is not caught, and no amount of containers fixes it.

**What would close it:** real VMs per distro — self-hosted runners or a nested-virt
provider. Not prototypable on the development host, which has no `/dev/kvm`. Deferred
again, and now the only gap of the three.

---

## F3 · A `.deb` package
**S3 · very plausible, but currently redundant**

A `.deb` would give versioning, integrity, correct paths, dependency declaration and
`apt`-native upgrades. Almost all of that is already being solved more cheaply:

| `.deb` would give | already covered by |
|---|---|
| versioning | F1 — tags + releases |
| integrity | F2 — `SHA256SUMS` |
| correct paths | D5 — derived from `ufw.common`, verified, refused if absent |
| dependency checks | X1 — the preflight, which checks more than a dependency list can |
| upgrade path | X4 — `curl` + re-run `install`, already idempotent |

What only a `.deb` gives is `apt`-native upgrade and a signed APT repo — meaningful, but
only with the ongoing commitment that implies: GPG key management, repo hosting, keyring
distribution to every host.

There is also a mild tension with the design. The single-file property is load-bearing —
*one file cannot be half-installed*, which is why `rescue` lives in the same file as
`install`. A `.deb` does not break that, but it adds a packaging layer plus maintainer
scripts, which are their own class of bug on a firewall tool.

**Brings it forward:** `curl`-install becoming real friction for netops, or a customer
requiring packaged software.
